# Google OAuth verification: whole-Drive access

What was submitted (or is to be submitted) to Google for the restricted scope
`https://www.googleapis.com/auth/drive`. The default scope, `drive.file`, is non-sensitive and needs no review.

## How the scope is used

StreamDisk is an open-source macOS app that shows the user's Google Drive as a disk in Finder.
Files appear at their real size and are streamed on demand when an app on the Mac reads them,
so large videos open in a second or two without downloading the whole file.

With the `drive` scope the app:

- lists the files and folders in the user's My Drive so Finder can show them;
- downloads byte ranges of a file when an app on the Mac reads it (held in memory);
- uploads files the user copies onto the disk, replaces a file's content when the user saves it,
  renames and moves files, and moves files to Drive's trash when the user deletes them;
- downloads full copies of files and folders the user explicitly chooses to keep offline.

All of this happens on the user's Mac. StreamDisk has no server: Google user data is sent only
between the Mac and Google's APIs. It is never sent to the developer or any third party, never
used for advertising, and never used to train AI or ML models. The source code is public at
https://github.com/ChinmayyK/streamdisk.

## Why a narrower scope is not enough

`drive.file` only gives access to files the app created or that the user opened with it. The
purpose of StreamDisk is to show the user's existing Drive library (photos, videos, archives,
documents) in Finder so any Mac app can open it; with `drive.file` that library is invisible.
`drive.readonly` would not let users save, add, rename or delete files from Finder, which a disk
must support. The Google Picker cannot grant access to a whole existing library and its future
contents, and Finder has no place to show a picker. `drive.file` remains the default; the user
chooses whole-Drive access explicitly at sign-in.

## Security assessment

Google requires a CASA assessment for apps that store or transmit restricted data on servers.
StreamDisk has no backend, proxy, sync service, logging or analytics that could receive Drive data;
all Drive access is from the user's device directly to Google APIs. We ask Google to confirm that no
assessment is required.

## Demo video (YouTube, Unlisted, English)

Record at 1080p with the app in light mode. About 3 minutes.

1. **Before sign-in.** Open StreamDisk (first run). Show the welcome window, click Get Started.
2. **Scope choice.** On "What should StreamDisk show?", select **Your whole Drive**, click
   Continue with Google.
3. **Consent screen.** In the browser, zoom into the address bar long enough to read the
   `client_id=…apps.googleusercontent.com` parameter. Choose the account, show the consent screen
   with the app name **StreamDisk** and the Drive permission, click Continue/Allow.
4. **Mounted.** Back in StreamDisk: "StreamDisk is ready". Click Open in Finder.
5. **Listing (`drive`).** In Finder, show StreamDisk under Locations with existing Drive folders and
   files that were not created by StreamDisk. Side by side with drive.google.com, show they match.
6. **Streaming read.** Double-click a large video; it plays within seconds. Open the menu bar
   window to show "Streaming".
7. **Write operations.** Drag a file onto the disk (upload; show it appear in drive.google.com).
   Rename it in Finder (rename shows in Drive). Delete it (show it in Drive's Trash).
8. **Keep offline.** Right-click a folder › Services › Keep on This Mac; show Settings › Kept on
   This Mac downloading.
9. **Sign out.** Settings › General › Sign Out; show StreamDisk removed at
   myaccount.google.com/permissions.

## Status

- 2026-11-08: domain chinmaykudalkar.com verified in Search Console (via Cloudflare). Branding
  (name, logo, home page, privacy policy, terms) submitted for verification. App published to
  production; whole-Drive users capped at 100 until data access is verified.
