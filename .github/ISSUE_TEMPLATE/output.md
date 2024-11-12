<!--
SPDX-FileCopyrightText: 2024 Eric Joldasov

SPDX-License-Identifier: CC0-1.0
-->

---
name: Feedback on generated output
about: All your feature requests are welcome here.
title: 'Output examination: '
labels: spec-generator
assignees: ''

body:
  - type: markdown
    attributes:
      value: |
        # Testing generated ebuilds
  - type: textarea
    id: source_url
    attributes:
      label: "Link to used project"
    validations:
      required: true
  - type: textarea
    id: output
    attributes:
      label: "Output of `zig-ebuilder`"
    validations:
      required: true
  - type: textarea
    id: request
    attributes:
      label: "What to change"
      description: "What exactly do you want for generator to add, remove or modify there?"
    validations:
      required: true
---
