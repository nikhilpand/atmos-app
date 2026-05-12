# Add Web Player Controls

The user requested adding a play/pause button, double-tap to seek, and TV remote (D-pad) controls to the web player (`player_screen.dart`).

## Open Questions
- Do we want to completely overlay the web player with native Flutter controls (blocking the web player's native UI), or just inject JS/keyboard listeners so we don't block interactions with the web player's quality/subtitle selectors?
*My proposed approach:* Use Flutter `Focus` for TV remote controls, and inject JS to handle double-taps on the video so we don't block the underlying web UI with a Flutter `GestureDetector` layer. For the play/pause button, we can either inject a native HTML button or add a Flutter overlay that doesn't consume all screen taps. I will add a central Play/Pause Flutter overlay that only consumes taps exactly on the button, leaving the rest of the screen interactive.

## Proposed Changes

### [MODIFY] lib/screens/player_screen.dart

1. **TV Remote Support**: 
   - Wrap the `Scaffold` in a `Focus` widget.
   - Listen to `KeyDownEvent` for `Select`, `Enter`, `MediaPlayPause` (to toggle play/pause).
   - Listen to `ArrowLeft` and `ArrowRight` (to seek -/+ 10s).
   - Call `_wv?.evaluateJavascript(source: ...)` to control the `<video>` element.

2. **Play/Pause Button**:
   - Add a `ValueNotifier<bool>` or state variable for `isPlaying`.
   - Poll the video state from JS using the existing `setInterval` or listen to JS events to update the `isPlaying` state.
   - Add a centered `IconButton` (Play/Pause) on top of the `InAppWebView` that shows when the controls are visible (along with the `_TopBar`).

3. **Double Tap to Seek**:
   - Inject JavaScript in `onLoadStop` to detect double-click events on the document or video element.
   - If `clientX < window.innerWidth / 2`, seek backward 10s.
   - If `clientX >= window.innerWidth / 2`, seek forward 10s.
   - Show a brief visual feedback (optional, we can do it via JS or call a Flutter handler).

## Verification Plan

### Manual Verification
- Press Enter/Select on a keyboard/remote to verify play/pause.
- Press Left/Right arrows to verify seeking.
- Double tap left/right side of the web player to verify seeking.
- Verify the centered play/pause button appears and functions.
