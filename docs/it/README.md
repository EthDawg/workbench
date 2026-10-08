# Workbench for IT administrators

What Workbench asks macOS for, who can switch each approval on, and the profiles that let a managed Mac use it without a help-desk ticket. Checked 8 October 2026 against Apple's PPPC schema (`com.apple.TCC.configuration-profile-policy`), Apple's Platform Deployment guide and macOS 26.5.1. The macOS 27 column comes from Apple's published App Settings schema and early reports. Nobody on the team has observed it on a macOS 27 Mac yet.

On the Mac, **Home › Permissions › Copy permission details** (press Show details first if the panel is folded) copies the same list along with that Mac's own answers: its edition and code requirement, whether the account is an administrator, MDM enrolment, and each approval's status. Ask the person for it when something doesn't work.

## Who can grant what

| Approval (System Settings name) | What Workbench uses it for | Can a standard account switch it on? | macOS 14–26 profile | macOS 27 |
| --- | --- | --- | --- | --- |
| Accessibility | Automatic paste: reads the focused text field and confirms the paste | No. macOS asks for an administrator's name and password. No PPPC option changes this | PPPC `Accessibility` = Allow | Keep the PPPC profile, with PostEvent (Apple says the grant applies with a notification; test it). Supervised Macs can also suggest Allow with App Settings `Privacy.PermissionDefaults` |
| Post Event (listed under Accessibility) | Automatic paste: sends ⌘V to the app being typed in | As Accessibility | PPPC `PostEvent` = Allow | As macOS 14–26 |
| Screen & System Audio Recording | Snap and Snap & Talk | Only if the profile lets standard users. Otherwise macOS asks for an administrator | PPPC `ScreenCapture` = AllowStandardUserToSetSystemService. A profile can't switch it on | As macOS 14–26 |
| Microphone | Dictate, Meetings, Snap & Talk | Yes, in macOS's request the first time. Changing it later in Settings may ask for an administrator | PPPC can only Deny | Supervised Macs: `PermissionDefaults` Microphone = Allow suggests it; the person accepts once |
| Camera | Present (iPhone over USB), Persona, profile photo | As Microphone | PPPC can only Deny | Supervised Macs: `PermissionDefaults` Camera = Allow suggests it; the person accepts once |
| System Audio Recording Only (call audio) | Meetings hears the other side of a call | Yes, in macOS's request the first time Meetings records a call | No key exists | No key exists |
| Desktop folder (optional) | Import Desktop screenshots, and reopening Snap & Talk sessions saved on the Desktop | Yes, in macOS's request | PPPC `SystemPolicyDesktopFolder` = Allow (optional) | As macOS 14–26 |
| Documents folder (optional) | Reopening Snap & Talk sessions saved in Documents | Yes, in macOS's request | PPPC `SystemPolicyDocumentsFolder` = Allow (optional) | As macOS 14–26 |

Workbench doesn't use Input Monitoring, Apple Events, Speech Recognition or Full Disk Access. Don't grant them for Workbench. Its shortcuts use Carbon hot keys, and its keyboard monitors already run under Accessibility.

Without Accessibility, dictation still works: the words are copied and the person pastes with ⌘V. Without Screen Recording, Snap takes pasted or imported images.

## Profiles

- [`Workbench-PPPC.mobileconfig`](Workbench-PPPC.mobileconfig) is for macOS 14–26, and stays the route on macOS 27 (see below). It sets Accessibility and PostEvent to Allow, ScreenCapture to AllowStandardUserToSetSystemService, and the Desktop and Documents folders to Allow (optional). It covers both editions. Delete the `com.ethdawg.workbench.preview` entries if you deploy only Workbench.
- [`Workbench-AppSettings-Privacy.macOS27.json`](Workbench-AppSettings-Privacy.macOS27.json) is the macOS 27 declarative `com.apple.configuration.app.settings` payload for supervised Macs: it suggests Allow for Accessibility, Microphone and Camera, and the person accepts once. macOS skips a permission it has already asked about, so on a Mac where Workbench already asked it may change nothing. Replace the `OrganizationJustification` text with your own.

Deliver the PPPC profile through your MDM on the **device channel**; a copy installed by hand grants nothing. Apple requires user-approved MDM, and its deployment guide also says supervision. Deliver the App Settings declaration on the **user channel**, where Apple scopes its Privacy settings. Replace the `PayloadIdentifier`, `PayloadOrganization` and `PayloadUUID` values if your MDM doesn't regenerate them.

## Identity

| Edition | Bundle ID | Team ID |
| --- | --- | --- |
| Workbench | `com.ethdawg.workbench` | GHVAAH9P5Z |
| Workbench Preview (testing) | `com.ethdawg.workbench.preview` | GHVAAH9P5Z |

The code requirement for Workbench is below. Preview's is the same with its own bundle ID.

```
identifier "com.ethdawg.workbench" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = GHVAAH9P5Z
```

It pins the bundle ID, Apple's Developer ID chain and the team, so it survives updates and certificate renewals. It doesn't match a locally built, ad hoc signed copy. Approve only notarized builds from the Workbench release feed.

## Worth knowing

- On macOS 14–26.1, approvals a profile grants don't appear in Privacy & Security's lists; from 26.2 they may. The device-management profile's details in System Settings always list them.
- macOS 27 and Accessibility profiles: Apple's 27.0 reference says a PPPC Accessibility grant still applies, with a notification, and the person can turn it off. During the 27 betas Apple DTS said the ability was removed, and testers saw the grant ignored unless PostEvent was also in the payload. Test on a macOS 27 Mac before relying on it, and keep PostEvent in the profile; the declarative replacement has no PostEvent key. On an unsupervised macOS 27 Mac, the PPPC profile is the only route.
- Check that your MDM supports the macOS 27 `com.apple.configuration.app.settings` declaration before relying on it. Vendor support hasn't been confirmed here. Microsoft Intune's Settings catalog configures PPPC natively.
- Updates: Workbench updates itself with Sparkle. A copy in `/Applications` that a standard account updates needs an administrator for each update, so deploy updates through your MDM there. A copy in the person's own `~/Applications` updates without one.
- `WorkbenchBrowserHost`, the Chrome helper inside the app, needs no privacy entry.
