# User Init Waiting State And Model Validation Design

## Context

`UserInitWizardView` currently has a weak long-wait experience during the `basicEnvironment` step. The panel mostly shows title, subtitle, and a terminate button, which leaves a large empty area during a 1-2 minute install window and feels unfinished when the network is slow.

The model configuration step also uses a mixed list-style picker plus direct API key entry, but does not clearly separate:

- provider selection
- auth method selection
- credential entry
- live validation before continuing

This creates avoidable uncertainty during onboarding.

## Goals

1. Make the `basicEnvironment` running state feel intentional and alive during a long wait.
2. Reuse the polish level of the existing finish state without duplicating it visually.
3. Reduce anxiety by showing that the system is actively progressing even when install speed varies.
4. Restructure model configuration so the information architecture matches future auth expansion.
5. Validate provider credentials before letting the wizard continue.

## Non-Goals

- Adding multiple auth methods in this change.
- Reworking the entire wizard layout or left rail.
- Building a full tutorial carousel.
- Changing helper-side install semantics unless required to support validation.

## Design Direction

### 1. Basic Environment Waiting Panel

The waiting panel should become a centered, visually substantial status surface rather than a sparse form section.

Structure:

1. Top text block:
   - title: `基础环境初始化`
   - subtitle: installation is in progress and may take 1-2 minutes or longer on slow networks
2. Central animated visual:
   - a lightweight “shrimp building home” motif
   - not cartoon-heavy; keep the overall UI restrained
   - animation should loop calmly and read well at a glance
3. Progress reassurance block:
   - indeterminate progress treatment, not fake percentage precision
   - rotating reassurance copy such as downloading dependencies, preparing runtime, checking environment
4. Secondary support area:
   - explain that the user can keep the window open and watch logs below
   - keep `终止初始化` available, but visually secondary to the status content

### 2. Animation Style

Recommended style: “interesting but restrained”.

Visual language:

- soft accent glow
- simple layered scene
- gentle vertical motion / tool motion / pulse
- no loud confetti, no novelty-heavy cartoon illustration

Implementation preference:

- SwiftUI-native animation only
- small set of animated primitives and SF Symbols / emoji if needed
- no external assets required for first version

### 3. UX Upgrades For Long Wait

The waiting state should add concrete reassurance:

1. Explicit long-wait expectation:
   - default copy says usually 1-2 minutes
   - slow network may take longer
2. Activity rotation:
   - cycle through a short set of status phrases every few seconds
3. Log discoverability:
   - point users to the collapsible log area rather than leaving them guessing
4. No fake deterministic progress:
   - use indeterminate or softly capped motion, not misleading exact completion numbers
5. Cancel action remains available:
   - button stays present but visually de-emphasized

## Model Configuration Redesign

### Information Architecture

Replace the current provider selection list with a form flow built around explicit fields:

1. `模型提供商`
   - dropdown
2. `认证方式`
   - dropdown
   - initial version contains only `API Key`
   - designed for future expansion to OAuth / CLI / other methods
3. `API Key`
   - shown when auth method is `API Key`
4. validation status area
   - `未验证`
   - `验证中`
   - `验证成功`
   - `验证失败`

### Primary Action

The main CTA should change from “保存并继续” to `验证并继续`.

Behavior:

1. Save the selected provider and entered API key.
2. Run a live provider probe.
3. If probe succeeds:
   - mark the model step done
   - continue to the next step
4. If probe fails:
   - stay on current step
   - show actionable error feedback

Secondary action:

- keep `稍后配置`

## Validation Command

Validation should use the current documented OpenClaw CLI shape:

`openclaw models status --probe-provider <name>`

Notes:

- The design should allow adding timeout tuning if needed.
- Probe results are real live checks, so the UI should clearly communicate that validation may take a short moment.
- Validation errors should be surfaced as credential/provider connectivity problems, not generic save failures.

## Error Handling

Model validation failure states should distinguish:

1. empty API key
2. unsupported / unavailable provider selection
3. probe command execution failure
4. auth rejected / invalid credential
5. timeout / transient network issue

UI copy should favor direct remediation guidance over raw terminal phrasing whenever possible.

## Implementation Outline

### `basicEnvironment` waiting panel

- Replace the current sparse `runningPanel` body with a richer centered waiting card.
- Add local animation state for:
  - looping scene motion
  - rotating status text
  - subtle pulse/glow
- Preserve existing cancellation logic.

### model config panel

- Convert provider chooser to dropdown.
- Add auth method dropdown state and UI.
- Rename the primary CTA to validation-first behavior.
- Add validation state and result messaging.
- Wire a probe command path around the selected provider.

## Testing

1. Manual:
   - enter model step with valid API key and confirm auto-advance on successful validation
   - enter invalid API key and confirm inline failure without step advance
   - verify waiting panel remains legible for extended idle observation
2. Regression:
   - `稍后配置` still works
   - existing finish-panel animation remains unchanged
   - terminate action during `basicEnvironment` still functions

## Open Decisions Already Resolved

1. Provider selection uses dropdown: yes
2. Auth method uses dropdown: yes
3. Initial auth methods supported now: API Key only
4. Validate before next step: yes
5. Waiting panel style: restrained but interesting, not overly cartoonish
