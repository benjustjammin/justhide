#!/usr/bin/env python3
"""Writes Resources/JustHide Focus.shortcut, the shortcut JustHide's Focus menu
switches modes through.

Why a shortcut: macOS gives no app a way to switch Focus. The Focus service
answers only entitled Apple processes -- it logs "XPC connection without any
valid entitlements tried to connect, will reject" even for one loaded into
Apple's own perl (measured on 27.2) -- but Shortcuts' "Set Focus" action can,
and `shortcuts run` runs it with no window.

ONE shortcut serves every mode, new ones included: "Set Focus" takes the mode
as TEXT (measured 2026-09-26: passing "Personal" turned Personal on), so the
mode is simply the input. Input is the mode's name to turn it on, or "off:"
and the name to turn it off.

The file is committed already signed, so building needs no iCloud:
    tools/make-focus-shortcut.py
    shortcuts sign --mode anyone -i /tmp/JustHide\\ Focus.shortcut \\
        -o "Resources/JustHide Focus.shortcut"
Run this and re-sign only when the actions change; the NAME a user sees is
the file's name.
"""

import plistlib
import sys
import uuid

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/JustHide Focus.shortcut"

# Shown at the top of the shortcut, where someone tidying Shortcuts will see it.
COMMENT = (
    "Made by JustHide, the menu bar app. JustHide runs this in the background "
    "to switch Focus modes from its Focus icon, because macOS gives apps no "
    "other way to do it.\n\n"
    "Please keep it, and keep its name. If it is deleted, JustHide's Focus menu "
    "will offer to add it again."
)


def new_uuid():
    return str(uuid.uuid4()).upper()


def action(identifier, **parameters):
    return {"WFWorkflowActionIdentifier": identifier,
            "WFWorkflowActionParameters": parameters}


def output_of(action_uuid, name):
    return {"Value": {"Type": "ActionOutput", "OutputUUID": action_uuid, "OutputName": name},
            "WFSerializationType": "WFTextTokenAttachment"}


def in_text_field(action_uuid, name):
    """The same variable, as a text FIELD wants it: a string with the
    variable standing in for its one character. A bare variable there reads as
    empty (measured: Set Focus was handed a Focus named "")."""
    return {"Value": {"string": "\ufffc",
                      "attachmentsByRange": {"{0, 1}": {"Type": "ActionOutput",
                                                        "OutputUUID": action_uuid,
                                                        "OutputName": name}}},
            "WFSerializationType": "WFTextTokenString"}


text_id, name_id, group = new_uuid(), new_uuid(), new_uuid()
text = output_of(text_id, "Text")
name = output_of(name_id, "Updated Text")

actions = [
    action("is.workflow.actions.comment", WFCommentActionText=COMMENT),
    action("is.workflow.actions.detect.text", UUID=text_id,
           WFInput={"Value": {"Type": "ExtensionInput"},
                    "WFSerializationType": "WFTextTokenAttachment"}),
    # The mode's name, with the "off:" taken away if there was one.
    action("is.workflow.actions.text.replace", UUID=name_id,
           WFInput=in_text_field(text_id, "Text"),
           WFReplaceTextFind="off:", WFReplaceTextReplace=""),
    # 8 is "begins with".
    action("is.workflow.actions.conditional", GroupingIdentifier=group, WFControlFlowMode=0,
           WFCondition=8, WFConditionalActionString="off:",
           WFInput={"Type": "Variable", "Variable": text}),
    action("is.workflow.actions.dnd.set", FocusModes=name, Enabled=0),
    action("is.workflow.actions.conditional", GroupingIdentifier=group, WFControlFlowMode=1),
    action("is.workflow.actions.dnd.set", FocusModes=name, Enabled=1),
    action("is.workflow.actions.conditional", GroupingIdentifier=group, WFControlFlowMode=2),
]

workflow = {
    "WFWorkflowActions": actions,
    "WFWorkflowClientVersion": "2607.0.2",
    "WFWorkflowMinimumClientVersion": 900,
    "WFWorkflowMinimumClientVersionString": "900",
    # A moon, on indigo, like Focus itself.
    "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 59511,
                       "WFWorkflowIconStartColor": 1440408063},
    "WFWorkflowImportQuestions": [],
    "WFWorkflowTypes": [],
    "WFQuickActionSurfaces": [],
    "WFWorkflowHasShortcutInputVariables": True,
    "WFWorkflowInputContentItemClasses": ["WFStringContentItem", "WFGenericFileContentItem"],
    "WFWorkflowOutputContentItemClasses": [],
}

with open(OUT, "wb") as f:
    plistlib.dump(workflow, f, fmt=plistlib.FMT_BINARY)
print(OUT)
