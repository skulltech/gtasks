# GTasks

A tiny macOS menu bar app for Google Tasks. Click the ✓ icon in the menu bar to see your list, add tasks, tick them off, and set due dates. No Dock icon, no browser tab.

- Shows one task list at a time, in Google's "My order" (switch lists from the header when you have more than one)
- Add a task (with an optional due date) from the field at the top
- Click the circle to complete a task, with Undo
- Double-click a title to edit it. Hover a row to set a due date or delete it; right-click for more
- Overdue dates show in red and "Today" in blue; the menu bar icon shows how many tasks are due today or overdue
- Links in task titles can be clicked
- Refreshes when you open it, every 5 minutes, and after the Mac wakes from sleep
- Optional Launch at Login (in the ⋯ menu)

## Build

Requires macOS 14+ and the Swift toolchain (Command Line Tools are enough; Xcode isn't needed).

```bash
./scripts/build-app.sh --install
```

This builds `build/GTasks.app`, copies it to `/Applications`, and launches it. Leave out `--install` if you only want the build. It needs `Resources/client_secret.json` first (see below).

## One-time Google setup (~3 minutes)

Google only lets apps reach your tasks through an OAuth client, so you create a personal one:

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create a project (e.g. "GTasks").
2. **APIs & Services → Library** → search for **Google Tasks API** → **Enable**.
3. **APIs & Services → OAuth consent screen** (also called "Google Auth Platform"):
   - **User type**: if your tasks are in a Google Workspace account and the project belongs to that organisation, choose **Internal**. Otherwise choose **External**.
   - Fill in an app name and your email address. You don't need to add scopes here.
   - For **External**: add your Gmail address under **Test users**, then under **Publishing status** click **Publish app** (set it to "In production").
     If you leave it in "Testing", Google expires the sign-in after 7 days and you'll have to sign in again every week. You don't need verification for personal use; Google will just show an "unverified app" warning once, which you can click through (**Advanced → Go to GTasks**).
4. **APIs & Services → Credentials → Create credentials → OAuth client ID** → Application type **Desktop app** → Create → **Download JSON**.
5. Save the downloaded file as `Resources/client_secret.json` in this repo (it's gitignored; `Resources/client_secret.example.json` shows the shape).
6. Run `./scripts/build-app.sh --install`, then open GTasks from the menu bar → **Sign in with Google**.

The build script copies the client JSON into the app bundle. Your Google refresh token is stored in the login Keychain. Because the app is ad-hoc signed, macOS may ask for Keychain access the first time after each rebuild; click **Always Allow**.

## Development

```bash
swift build
```

```bash
swift run
```

`swift run` works too (the app hides its Dock icon on its own), but Launch at Login only works from the installed `.app`.

Code layout (`Sources/GTasks`):

| File | What it does |
| --- | --- |
| `GTasksApp.swift` | App entry point and `MenuBarExtra` |
| `Auth.swift` | Loads the bundled OAuth client; sign-in (loopback redirect + PKCE), token refresh, Keychain storage |
| `TasksAPI.swift` | Google Tasks REST v1 client |
| `TaskStore.swift` | State, ordering, optimistic updates |
| `Views.swift` | SwiftUI UI |
| `Local.swift` | `@Local`, a replacement for `@State`: on this SDK `@State` is a macro whose plugin only ships with Xcode |
