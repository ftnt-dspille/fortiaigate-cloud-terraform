"""The FortiAIGate 8.0.2 workshop's per-student objects and Module 2 exercises.

One definition shared by the instructor tool (`faig_class.py`: build / reset a
student's workspace) and the student tool (`config/student/files/guard_step.py`:
the student's own clicks), so the starting state and the exercises cannot drift.

Per student `<sid>` (e.g. student03) the instructor pre-creates, in workspace <sid>:

  <sid> Baseline      regex detector, one pattern nothing contains, disposition log.
                      Exists only because a guardrail needs >= 1 detector.
  <sid> DLP           DLP detector, a harmless log-only starter category; the
                      student sets the real categories in 2a.
  <sid> Custom Rules  regex detector, the no-op starter pattern; the student writes
                      the real rules in 2d.
  <sid> Input         guardrail = [Baseline]      -> every use case MISMATCHes
  <sid> Output        guardrail = [Baseline]
  <sid> Policy        Input + Output, post-stream scan

The student creates their own virtual key (Lab 0). Every student edit becomes a
pending change an org admin must approve -- see faig_class.py `approve`.

Detector choices are live-measured (docs/plans tracker, section C):
  2b MITRE ATLAS -- OWASP LLM Top 10 and LLM Security Guide block the benign HR
     question; OWASP AI Exchange and General AI Safety block the toxic prompt
     too, which would erase 2c's before/after flip. ATLAS also flags the DLP
     prompts as credential exfiltration (sometimes one, sometimes both), so DLP
     runs first as 2a or its before/after flip is gone.
  2c MLCommons AILuminate -- blocks the toxic prompt, passes the benign
     historical question about the same keyword.
"""
from __future__ import annotations

from faig802 import ai_detector_body, dlp_detector_body, regex_detector_body

BASELINE_PATTERN = "FAIG-WORKSHOP-BASELINE-7f3c9a"
STARTER_DLP_CATEGORY = "PIN"  # log-only until the student edits it in 2a


def names(sid: str, workspace: str | None = None) -> dict[str, str]:
    """Object names for one student. `workspace` (vars `faig_workspace`) puts them in
    an EXISTING workspace on an always-on FAIG instead of one named after the
    student; the `<sid> ` prefix is then what marks the objects as the student's."""
    return {
        "workspace": workspace or sid,
        "baseline": f"{sid} Baseline",
        "dlp": f"{sid} DLP",
        "rules": f"{sid} Custom Rules",
        "nightingale": f"{sid} Nightingale",
        "darkside": f"{sid} Dark Side",
        "input": f"{sid} Input",
        "output": f"{sid} Output",
        "policy": f"{sid} Policy",
    }


def baseline_body(sid: str) -> dict:
    return regex_detector_body(names(sid)["baseline"], [("Never matches", BASELINE_PATTERN, "log")],
                               "Workshop placeholder: a guardrail needs at least one detector")


def starter_dlp_body(sid: str) -> dict:
    return dlp_detector_body(names(sid)["dlp"], [STARTER_DLP_CATEGORY], disposition="log",
                             description="Configure the data types to block in Module 2a")


def starter_rules_body(sid: str) -> dict:
    return regex_detector_body(names(sid)["rules"], [("Starter", BASELINE_PATTERN, "log")],
                               "Write your custom rules in Module 2d")


# Module 2, in page order. Each exercise is what the page tells the student to do:
#   detector: a built-in id to add, OR (edit) a custom detector the student rewrites
#   stage:    the guardrail it goes on
EXERCISES: dict[str, dict] = {
    "2a": {"use_case": "DLP", "stage": "input", "custom": "dlp",
           "label": "your Data Leak Prevention detector",
           "body": lambda sid: dlp_detector_body(
               names(sid)["dlp"], ["Credit/debit card", "CVV", "Email address", "Password"],
               disposition="block", description="Block payment card data and credentials")},
    "2b": {"use_case": "Prompt Injection", "stage": "input", "builtin": "mitre-atlas",
           "label": "MITRE ATLAS"},
    "2c": {"use_case": "Toxicity", "stage": "input", "builtin": "mlcommons-ailuminate",
           "label": "MLCommons AILuminate"},
    "2d": {"use_case": "Custom Rule", "stage": "output", "custom": "rules",
           "label": "your Custom Rules regex detector",
           "body": lambda sid: regex_detector_body(names(sid)["rules"], [
               ("Block Salary Info", r"\$[0-9]{2,3},[0-9]{3}", "block"),
               ("Block Project Codename", r"(?i)project nightingale", "block"),
               ("Block Confidential Marking", "INTERNAL USE ONLY", "block"),
           ], "Salary figures, project codename, document marking")},
    # Natural Language detectors (Step 6). These do not exist in the student
    # workspace at setup time; the student creates them with Detectors ->
    # Submit Detector -> Natural Language and adds them to the Input Guardrail.
    # The walkthrough's `guard_step add` creates them (if absent) and attaches.
    "2e": {"use_case": "Nightingale", "stage": "input", "custom": "nightingale",
           "create_if_absent": True,
           "label": "your Nightingale Natural Language detector",
           "body": lambda sid: ai_detector_body(names(sid)["nightingale"], [
               ("Nightingale project",
                "The text discusses, asks about, or reveals Project Nightingale, however it is worded.",
                "The text is a general question about project management that does not mention Nightingale."),
           ], action="block", description="Any mention of Project Nightingale")},
    "2f": {"use_case": "Dark Side", "stage": "input", "custom": "darkside",
           "create_if_absent": True,
           "label": "your Dark Side Natural Language detector",
           "body": lambda sid: ai_detector_body(names(sid)["darkside"], [
               ("Palo Alto praise",
                ["The text praises, recommends, or speaks favorably about Palo Alto Networks or any of its products, however it is worded.",
                 "The text asks to order, buy, or procure Palo Alto Networks (PANW) products."],
                "The text asks a neutral, factual question about Palo Alto Networks or compares it with Fortinet without praising it."),
           ], action="block", description="Palo Alto praise or purchase orders")},
}
