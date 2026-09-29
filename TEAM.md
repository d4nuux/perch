# Team rules (wave 2)

- Work in your own copy: `rsync -a --exclude .build --exclude build ~/Code/perch/ $SCRATCH/agents2/<you>/` where
  SCRATCH=/private/tmp/claude-501/-Users-danu/93ad8424-e575-4fe0-8b65-a2357f860f14/scratchpad. Never edit ~/Code/perch.
- Edit ONLY the files/folders you own (listed in your brief). Need something elsewhere? Put the exact change in your report.
- Public APIs other folders use must keep their names/signatures: NotchModel (open/close/selectTab/present/dismissActivity/
  activity/isExpanded/tab/notchSize/quietMode/suppressHoverOpen), LiveActivity, NotchContext, NowPlaying (title/artist/
  isPlaying/position/duration/appIcon/artwork/hasTrack/send/seek), Equalizer, WeatherService/WeatherSnapshot,
  every *SettingsSection view, CalendarService/CalendarTab, SettingsWindow.show(), the service init(context:) signatures.
- Settings: keep new options in your own ObservableObject (UserDefaults-backed, `static let shared`) inside your folder,
  and expose UI rows by filling in your `<Name>SettingsSection` view (Form rows, no Section header—Settings wraps it).
- Toolchain is Command Line Tools only: NO SwiftUI `@State` macro, `#Preview`, `@Observable`, `@AppStorage`.
  Use ObservableObject/@StateObject/@ObservedObject/@Published. `swift build` must pass with zero errors.
- Never launch the GUI app, take screenshots, kill NotchApp, lock the screen, or play sounds/media on the user's machine
  (they're on calls). Small standalone CLI probes are fine. Don't print personal data (calendar, location).
- Keep idle CPU ~0: event-driven over polling; any timer must be justified.
- Visual style: black notch, white text, secondary opacity ~0.55, SF Symbols, 11–14pt, spring animations. Our own design.
- Report (final message, concise): files changed, behavior, what's verified vs not, core changes needed.
