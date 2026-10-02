# Security policy

## Reporting a vulnerability

Please report security problems privately through GitHub:
**[Report a vulnerability](https://github.com/fspecii/LinPad/security/advisories/new)**
(the repository's Security tab › "Report a vulnerability").

Do not open a public issue for a security problem. Include the LinPad version, the iPadOS
version, what an attacker can do, and the steps to reproduce. You should get a first reply
within 7 days. Once a fix ships, the advisory is published with credit to you unless you
ask otherwise.

## Supported versions

Only the latest release on [GitHub Releases](https://github.com/fspecii/LinPad/releases)
gets security fixes. The bundled Linux system is updated through Settings › Updates.

## Security model

LinPad runs a Linux userland inside a single iPadOS app, on the
[iSH](https://github.com/ish-app/ish) emulator. The iPadOS app sandbox is the security
boundary. The Linux layer inside it is not: there is one user, root, and it can read
everything the app can read. Do not use LinPad to isolate untrusted code from your other
data inside the app.

**In scope** (please report privately):

- A web page, file, theme or `linpad://` link that runs code or changes settings in LinPad
  without the user agreeing to it.
- Anything that lets code inside LinPad escape the iPadOS app sandbox, or reach iPad
  folders the user did not mount.
- Update, repair-kit or theme downloads that can be tampered with in transit (a missing or
  bypassable checksum or signature check).
- Leaks of data from LinPad to a third party that the app does not disclose.

**Usually not security bugs** (please file a normal issue): missing permission checks or
memory-safety bugs between Linux processes inside the guest, crashes caused by a program
you chose to run, and problems in Alpine packages themselves (report those to
[Alpine](https://security.alpinelinux.org/)).

## Third-party software

LinPad bundles Alpine Linux packages and downloads some apps on request (for example
Visual Studio Code, Wine). Security problems in those projects belong upstream; tell us
too if LinPad needs an update to pick up their fix.
