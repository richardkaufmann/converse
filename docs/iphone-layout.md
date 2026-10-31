# iPhone layout proposal and first implementation

Use the existing iOS app as a universal viewer/controller, preserving its pairing and session protocol. No provider keys or model processes move onto the phone.

- Default to one full-height session in portrait. Allow a second session directly below it; avoid side-by-side transcripts on a phone.
- A subtle stacked-rectangles button opens a session sheet. Keep the icon visually quiet but retain a 44-point touch target and a descriptive VoiceOver label.
- Select or deselect up to two sessions with checkmarks. Group by home, show status, and keep creation, pairing, Help and About in the same sheet. Keep destructive session actions in the existing explicit session-action sheet.
- When the software keyboard opens, show the focused session and collapse the other to its title strip. Dismissing the keyboard restores both. The title strip lets the user switch context without losing either draft.
- Preserve iPad's existing sidebar/three-pane behavior. Short phone windows, including landscape, show one expanded session and the other title strip; portrait is the primary two-session workspace.
- Distinguish installations with a persisted default mobile name suffix. Group membership remains keyed by device identity, so several phones and tablets coexist; taking the same session still transfers its display lease.

## Acceptance still needed on a physical phone

Check thumb reach, the software keyboard with long drafts, rotation, large Dynamic Type, VoiceOver, Photos imports, background/reconnect, and pairing two phones alongside two iPads. Simulator coverage does not establish real-device networking, keyboard ergonomics or App Store availability.
