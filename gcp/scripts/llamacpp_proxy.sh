#!/usr/bin/env bash
set -euo pipefail

# llamacpp_proxy.sh -- put an nginx sidecar in front of llama.cpp. Idempotent; ready.sh
# calls it on every `make up`, after llamacpp_gpu.sh.
#
# Why: llama.cpp's HTTP server closes a keep-alive connection that has been idle for
# more than 5 seconds (measured: a reused connection works at 4.5 s idle, breaks at
# 5.5 s; the server has no flag for it). The FortiAIGate gateway pools connections to
# the model, so the first request after any pause longer than 5 s went out on a dead
# connection and came back as a 500 ("The provider returned an internal server error").
# Three of those in a row opened the gateway's circuit breaker ("every upstream
# credential for this model is currently unavailable", 503) for several minutes, on a
# pool of one credential, which is what students saw in class.
#
# The sidecar listens on 8090, keeps the gateway's side open for 10 minutes and opens a
# fresh loopback connection to llama.cpp per request, so there is never a stale one.
# The Service's targetPort moves to it; llama-server itself is unchanged. It also logs
# every request (status, timings, connection reuse) for `faig-diag`.
#
# Verified live: before, a burst after an 8 s pause produced 500s and then 503s; after,
# 144/144 requests across 8 s, 30 s and 90 s pauses succeeded with client retries off.
#
# It also returns llama.cpp's own HTTP 500 to the gateway as 422. llama.cpp answers 500
# when one reply is unusable, e.g. a malformed tool call ("The model produced output that
# does not match the expected peg-native format"), while the server is healthy. The
# gateway counts every 500 against the model's single credential, so one student retrying
# one tool-calling prompt three times took the model away from the whole class for ~6
# minutes (2026-11-11). A real outage still reaches the gateway as a failure: llama.cpp
# down or crashed is a connection error, which nginx returns as 502/504.
#
# Config changes: edit the ConfigMap below, re-run, then
#   kubectl -n llamacpp rollout restart deploy/llamacpp
# Undo: kubectl -n llamacpp patch svc llamacpp --type=json \
#   -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'
#
# Usage: llamacpp_proxy.sh [vm-name]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
PROXY_IMAGE="${LLAMACPP_PROXY_IMAGE:-nginx:1.27-alpine}"

gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
  --command="PROXY_IMAGE='$PROXY_IMAGE' bash -s" << 'REMOTE'
set -euo pipefail
k() { sudo k3s kubectl -n llamacpp "$@"; }

sudo k3s kubectl apply -f - << 'CONFIGMAP'
apiVersion: v1
kind: ConfigMap
metadata: {name: llamacpp-proxy, namespace: llamacpp}
data:
  nginx.conf: |
    worker_processes 1;
    error_log /dev/stderr warn;
    events { worker_connections 2048; }
    http {
      # llama.cpp closes a connection idle for more than 5 s. The gateway pools connections
      # and reuses the stale ones, so the first request after a pause failed with a 500 and
      # three of those opened the gateway's circuit breaker. This proxy keeps the gateway's
      # side open long and uses a fresh loopback connection to llama.cpp for every request.
      keepalive_timeout 600s;
      keepalive_requests 100000;
      log_format faig 'ts=$time_iso8601 client=$remote_addr req="$request" status=$status bytes=$body_bytes_sent rt=$request_time urt=$upstream_response_time ustatus=$upstream_status conn=$connection conn_reqs=$connection_requests';
      access_log /dev/stdout faig;
      server {
        listen 8090;
        location = /health {
          access_log off;
          proxy_pass http://127.0.0.1:8080;
          proxy_set_header Connection close;
        }
        location / {
          proxy_pass http://127.0.0.1:8080;
          proxy_http_version 1.1;
          proxy_set_header Connection close;
          proxy_set_header Host $host;
          proxy_buffering off;
          proxy_request_buffering off;
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
          proxy_next_upstream error timeout;
          proxy_next_upstream_tries 2;
          # One unusable reply is not a provider failure: 500 -> 422 (see the header).
          proxy_intercept_errors on;
          error_page 500 = @model_error;
        }
        location @model_error {
          default_type application/json;
          return 422 '{"error":{"code":422,"type":"invalid_request_error","message":"The model produced a response it could not complete (for example a malformed tool call). Retry or rephrase the prompt."}}';
        }
      }
    }
CONFIGMAP

has_proxy=$(k get deploy llamacpp -o jsonpath='{.spec.template.spec.containers[*].name}' | grep -c llama-proxy || true)
target=$(k get svc llamacpp -o jsonpath='{.spec.ports[0].targetPort}')
# nginx reads its config only at start: stamp the config's hash on the pod template so a
# changed ConfigMap rolls the pod (an unchanged one leaves it alone).
want_hash=$(k get cm llamacpp-proxy -o jsonpath='{.data.nginx\.conf}' | sha256sum | cut -c1-16)
have_hash=$(k get deploy llamacpp -o jsonpath='{.spec.template.metadata.annotations.faig-proxy-conf}')
if [ "$has_proxy" = 1 ] && [ "$target" = 8090 ] && [ "$want_hash" = "$have_hash" ]; then
  echo "  llama.cpp proxy already in place"
  exit 0
fi

if [ "$has_proxy" = 0 ]; then
  echo "  adding the llama.cpp proxy sidecar ($PROXY_IMAGE)..."
  k patch deploy llamacpp --type=strategic -p '{"spec":{"template":{"spec":{
   "containers":[{"name":"llama-proxy","image":"'"$PROXY_IMAGE"'","ports":[{"containerPort":8090,"name":"proxy"}],
    "volumeMounts":[{"name":"proxy-conf","mountPath":"/etc/nginx/nginx.conf","subPath":"nginx.conf"}],
    "resources":{"requests":{"cpu":"50m","memory":"32Mi"},"limits":{"cpu":"1","memory":"128Mi"}},
    "readinessProbe":{"httpGet":{"path":"/health","port":8090},"periodSeconds":5}}],
   "volumes":[{"name":"proxy-conf","configMap":{"name":"llamacpp-proxy"}}]}}}}'
fi
if [ "$want_hash" != "$have_hash" ]; then
  echo "  proxy config changed: restarting the llama.cpp pod to load it"
  k patch deploy llamacpp --type=merge \
    -p '{"spec":{"template":{"metadata":{"annotations":{"faig-proxy-conf":"'"$want_hash"'"}}}}}'
fi
k patch svc llamacpp --type=json -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8090}]'
k rollout status deploy/llamacpp --timeout=300s
REMOTE
