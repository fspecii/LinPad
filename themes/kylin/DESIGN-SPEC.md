# Kylin (UKUI 4.x) design spec for the `kylin` DesktopKit style

The values below were read from the UKUI source, not from screenshots. Every value is cited `repo/path:line`, relative to `themes/kylin/src/`. These are shallow clones; the folder is git-ignored through `themes/kylin/.gitignore`.

## 0. Sources and which ones are canonical

| Repo (gitee.com/openkylin) | Branch | Commit / date | Used for |
|---|---|---|---|
| ukui-panel | upstream | 3b38abe, 2026-09-30 | taskbar |
| ukui-menu | upstream | 7637e8d, 2026-09-28 | start menu |
| ukui-quick | upstream | bbe55b5, 2026-09-28 | QML theme API: `GlobalTheme`, `DtThemeBackground` |
| ukui-globaltheme | upstream | b97d025, 2025-05 ("ukui 4.20.0.0") | **design tokens**: `*.css`, `theme.conf` |
| qt5-ukui-platformtheme | upstream | bef8e72, 2026-07 (4.24.0.0) | Qt style metrics, `org.ukui.style` schema |
| kwin (openKylin fork) | openkylin/huanghe | sparse checkout | `src/plugins/kdecorations/ukui` (window decoration), shortcuts, tiling |
| ukui-window-switch, ukui-sidebar, ukui-notification, ukui-settings-daemon, peony, ukui-control-center | upstream | 2026 | multitask view, sidebar, notifications, keys, file manager, settings |
| ukui-theme | upstream | ddd06fe, 2023-12 | GTK theme and icons. Older than the Debian package; see §9 |

- **The GitHub `ukui` org is stale.** Its newest relevant pushes are from 2022–24. **Gitee `openkylin` is canonical**; its `upstream` branch is UKUI 4.x.
- Debian sid/forky packages `ukui-themes` **4.0.0.1-1**, built from gitee `openkylin/ukui-themes` tag `debian/4.0.0.1-1`. This is the newest packaged GTK theme and icon set.
- The default global theme is **"Light-Seeking" (寻光)**, `ukui-globaltheme/globaltheme/Light-Seeking/`. Other global themes are HeYin (purple, "fashion" widgets), Classic (square corners, `windowRadius=0`) and v11.

---

## 1. Design tokens (use these everywhere)

### 1.1 Accent ("theme color") list

From `ukui-globaltheme/globaltheme/globaltheme.conf:3-11`. The user picks one in Control Center → Personalized.

| id | name | RGB | hex |
|---|---|---|---|
| kbrand1 (**default**) | daybreakBlue | 55,144,250 | `#3790FA` |
| kbrand2 | jamPurple | 137,38,235 | `#8926EB` |
| kbrand3 | magenta | 228,74,232 | `#E44AE8` |
| kbrand4 | dustGold | 242,181,39 | `#F2B527` |
| kbrand5 | polarGreen | 20,166,33 | `#14A621` |
| kbrand6 | sunRed | 240,73,67 | `#F04943` |
| kbrand7 | sunsetOrange | 250,125,15 | `#FA7D0F` |
| kbrand8 | Azure | 54,118,245 | `#3676F5` |
| kbrand9 | hillsCyan | 6,192,199 | `#06C0C7` |

**Brand states** (`Light-Seeking/kdefault-light.css:37,40`):
- hover = brand with a black overlay at 0.05
- pressed = brand with a black overlay at 0.20
- focus ring = `KFont-Strong`, 2px (`--focusline: 2px`, :20)

**Status colors:**

| Role | Light | Dark |
|---|---|---|
| error | `#F53F3F` | `#F04943` |
| success | `#00B42A` | `#14A621` |
| warning | `#FF7D00` | `#FA7D0F` |

Light values are at `kdefault-light.css:106,131,136`; dark values at `kdefault-dark.css:106,131,136`.

### 1.2 Neutral ramp

From `kdefault-light.css:74-91` and `kdefault-dark.css:74-91`.

| token | light | dark | used for |
|---|---|---|---|
| KGray-0 | `#FFFFFF` | `#1E1E1E` | base: content, list and editor backgrounds |
| KGray-1 | `#FAFAFA` | `#222222` | |
| KGray-2 | `#F6F6F6` | `#2E2E2E` | **window / panel / menu background** (`--window-active`, `--kmenu`) |
| KGray-3 | `#F2F2F2` | `#363636` | contain-hover |
| KGray-4 | `#EEEEEE` | `#3C3C3C` | contain-click, disabled component |
| KGray-6 | `#E6E6E6` | `#4A4A4A` | **button background** (`--button-active`, `--kcomponent-normal`) |
| KGray-7 | `#DCDCDC` | `#545454` | button hover |
| KGray-10 | `#B9B9B9` | `#737373` | button pressed |
| KGray-13 | `#737373` | `#A0A0A0` | mid |
| KGray-17 | `#262626` | `#F0F0F0` | |

**Alpha ramp** (`kdefault-light.css:92-105`). In light mode it is black at the given alpha; in dark mode white at the same alpha.

| Alpha step | Value |
|---|---|
| Alpha1 | 0.05 |
| Alpha2 | 0.08 |
| Alpha3 | 0.10 |
| Alpha4 | 0.15 |
| Alpha6 | 0.20 |
| Alpha9 | 0.30 |
| Alpha10 | 0.35 |
| Alpha11 | 0.55 |
| Alpha12 | 0.03 |

**Semantic alpha roles** (`kdefault-light.css:42-60`):

| Role | Normal | Hover | Click | Disabled |
|---|---|---|---|---|
| component-alpha (flat buttons on translucent surfaces: panel, menu) | Alpha3 | Alpha4 | Alpha6 | Alpha2 |
| contain-alpha (list rows) | — | Alpha1 | Alpha2 | — |

- divider = Alpha3
- `--kline-window-active` = Alpha3, the 1px window outline (:127)

### 1.3 Text

| token | light | dark |
|---|---|---|
| KFont-Primary | black 0.85 | white 0.90 |
| KFont-Secondary | black 0.60 | white 0.60 |
| KFont-Primary-Disable | black 0.35 | white 0.30 |
| KFont-Strong | black 1.0 | white 1.0 |
| placeholder | black 0.55 | white 0.50 |
| text on highlight | white | white 0.90 |

Light values: `kdefault-light.css:65-73,171`. Dark values: `kdefault-dark.css:66-72`.

**Inactive window text** is `--windowtext-inactive: KFont-Secondary-Disable` (light :196). Inactive windows really do grey their text.

### 1.4 Typography

| Role | Spec | Source |
|---|---|---|
| text-min | 400 12px | `kdefault-light.css:180` |
| text-normal (body) | 400 14px | :181 |
| title-small | 400 16px | :184 |
| title-medium | 400 18px | :183 |
| title-large | 400 24px | :182 |

- The token family is `"Noto Sans CJK SC"`.
- The shipped system font default is `"方正雅意黑 GB18030L2"` at **10pt**, Regular (`qt5-ukui-platformtheme/libqt5-ukui-style/settings/org.ukui.style.gschema.xml:19-29`). That font is proprietary (FounderType).
- **Substitute: Noto Sans CJK SC** (SIL OFL 1.1), Alpine `font-noto-cjk`, 72 MB. For Latin-only text, Noto Sans (`font-noto`, already installed) has the same metrics family.
- **In SwiftUI:** body = system 14, secondary = 12, window titles = 14 regular (UKUI uses the system font size; it does not bold titles).

### 1.5 Radii, lines, shadows, motion, translucency

| Token | Value | Source |
|---|---|---|
| kradius-min | 4 (checkbox, small chips, menu list rows) | `kdefault-light.css:133` |
| kradius-normal | **6** (buttons, inputs, taskbar tiles, nav items) | :134 |
| kradius-menu | **8** (menus, tooltips, popups, quick-settings tiles) | :132 |
| kradius-window | **12** (windows, start menu, sidebar, task-view cards) | :135; `Light-Seeking/theme.conf:20` |
| User radius presets | Big "12,8", Small "6,4", Right-angle "0,0" (window, menu pairs) | `globaltheme.conf:15-17`; `org.ukui.style` `window-radius` default "12,8" (gschema :96-97) |
| Lines | normal 1px, focus 2px | `kdefault-light.css:167,20` |
| Shadow, menu | 0 4 20 0 black 0.20 | :137 |
| Shadow, primary window, active / inactive (light) | 0 22 38 0 black 0.30 / 0 15 25 0 black 0.20 | :139-140 |
| Shadow, primary window, active / inactive (dark) | 0 30 100 0 black 0.40 / 0 30 100 0 black 0.25 | `kdefault-dark.css:139-140` |
| Modal scrim | black 0.20 | `kdefault-light.css:130` |
| Global animation duration | **150 ms** | `Light-Seeking/theme.conf:13` |
| Translucency | panel, menu, sidebar and nav-sidebar alpha **0.65** with blur; 0.90 without blur; user range 0.35–1 | `theme.conf:18-19`; `globaltheme.conf:21`; `ukui-control-center/data/org.ukui.control-center.personalise.gschema.xml:3-4` (`transparency` 0.65); `org.ukui.style` `menu-transparency` 65, `peony-side-bar-transparency` 65 (gschema :41-47) |
| Blur | enabled by default (`enabled-global-blur` true, gschema :33) | |

**Translucency rule.** Every `DtThemeBackground` multiplies its color by `GlobalTheme.transparency` unless `useStyleTransparency:false` (`ukui-quick/items/qml/DtThemeBackground.qml:63,106`).

- **Translucent + blurred:** panel, start menu, sidebar, menus, and app nav sidebars. In the reference image the Control Center's left pane is frosted while the content pane is opaque white.
- **Opaque:** window content, buttons and tiles.

**Control-level motion** (`qt5-ukui-platformtheme/ukui-styles/qt5-config-style-ukui/animations/`):

| Control | Animation | Duration | Easing | Source |
|---|---|---|---|---|
| Button | hover | 100 ms | OutCubic | `config-button-animator.cpp:68-69` |
| Button | press | 75 ms | InCubic | :75-76 |
| Slider | — | 100–200 ms | InOutCubic | `config-slider-animator.cpp:100-138` |
| Tree | expand / collapse | 250 ms | InOutCubic | `config-tree-animator.cpp:81-89` |

- Shell surfaces (menu, sidebar, notifications) use **300 ms InOutQuad**, or bezier (0.25, 0.1, 0.25, 1). See §3, §6 and §7.

### 1.6 Control metrics (Qt style "default" widget theme)

From `qt5-ukui-platformtheme/ukui-styles/qt5-config-style-ukui/ukui-config-style-parameters.h`:

| Control | Size | Line |
|---|---|---|
| Push button | 88×**36** min, margin 8, icon 16 | 214-221 |
| Tool / icon button | 60 / **36×36** | 223-224 |
| Line edit, combo box, spin box | 160×**36** | 303-321 |
| Checkbox / radio | 16, row 36, checkbox radius 4 | 289-300 |
| Menu | item height **36**, min width 152, item padding 12+4, menu vertical margin 8, separator margin 4 | 238-256 |
| Tooltip | height 36, margin 7 | 337-339 |
| Tab | height 42 (40 orig), width 168–248 | 324-327 |
| List / table row and header | 36 | 342-347 |
| Scrollbar | 16 wide, handle min 68 | 259-262 |
| Slider | handle 20, groove 4 | 279-286 |
| Progress bar | thickness 16 | 266-267 |

- A "4_3" variant scales rows to 48 for tablet / touch (:356).
- Spacing grid (`ukui-quick/platform/ukui/DtThemeDefault.qml:482-485`): 4 / 8 / 16 / 24 (`kMarginMin`, `Normal`, `Big`, `Window`). **Use an 8pt grid with a 4pt half-step.**

> `ukui-quick/platform/ukui/DtThemeDefault.qml` contains *fallback* values (e.g. brand `#3676F5`, gray2 `#F5F5F5`, font 0.88). They apply only when no global-theme token file is installed. **The Light-Seeking CSS above is what ships.**

---

## 2. Panel (taskbar), ukui-panel "classic" (`org.ukui.panel`)

| Property | Value | Source |
|---|---|---|
| Position | **bottom**; draggable to any edge | `ukui-panel/panel/src/view/panel.cpp:297`; enum `general-config-define.h:34-39` |
| Height | **48** (Small, default). Medium 72, Large 92, Custom between 48 and 92 | `panel.cpp:57,294,298,342-343,673-683` |
| Scale | `ratio = clamp(panelSize/48, 1, 2)`; every inner metric × ratio | `panel/qml/org.ukui.panel/ui/Container.qml:49` |
| Shape | full width, radius 0, margins 0, padding 0 | `panel.cpp:284-296` |
| Background | `GlobalTheme.windowActive` (KGray-2: `#F6F6F6` light / `#2E2E2E` dark) × transparency 0.65, with blur behind (`blur-region-helper.cpp`) | `Container.qml:97-107`; `DtThemeBackground.qml:72,106` |
| Top edge | no border line (`border.width: 0`) | `Container.qml:106` |
| Layout | two groups: **appView** left-aligned, leftMargin 8·r, item spacing 4·r; **configView** right-aligned, spacing 0; 32·r between groups | `Container.qml:45-48, 351-391` |
| Tray area limit | at most 38.2% of panel length | `Container.qml:39-40` |

**Default widget order** (`panel.cpp:447-457`). Layout index 0 = left group, 1 = right group.

| # | Widget | Group | Look |
|---|---|---|---|
| 1 | `org.ukui.menu.starter` | left | square tile, inset 4·r, radius 6, icon `kylin-startmenu` |
| 2 | `org.ukui.panel.search` | left | square tile, icon `kylin-search` (removable) |
| 3 | `org.ukui.panel.taskView` | left | square tile, icon `ukui-taskview-black-symbolic` (removable) |
| 4 | `org.ukui.panel.separator` | left | 1px line, 50% of panel height |
| 5 | `org.ukui.panel.taskManager` | left, fills the rest | pinned and running apps (below) |
| 6 | `org.ukui.systemTray` | right | status icons (the tray widget's repo was not in these clones) |
| 7 | `org.ukui.panel.calendar` | right | clock (below) |
| 8 | `org.ukui.ai.assistant` | right | **skip** |
| 9 | `org.ukui.panel.showDesktop` | right | thin strip at the far right edge |

Sources: starter `widgets/ukui-menu-starter/widget/ui/*.qml:86-125`; search `widgets/ukui-panel-search/widget/ui/*.qml:82-100`; task view `widgets/ukui-panel-taskView/widget/ui/*.qml:84-104`; separator `widgets/ukui-panel-separator/widget/ui/*.qml:39-44`; show desktop `widgets/ukui-panel-showDesktop/widget/ui/*.qml:36-41`.

The show-desktop strip is **(15·r + 2) wide**, full height, with hover and press fill only.

**Common tile states** for the starter, search, task view, clock and task buttons:

| State | Fill |
|---|---|
| Rest | transparent (`kContainGeneralAlphaNormal` = Alpha0) |
| Hover | `kComponentAlphaHover` (black 0.15 / white 0.15) |
| Pressed | `kComponentAlphaClick` (0.20) |
| Keyboard focus | 2px `kBrandFocus` border |

All tiles have radius 6. Sources: `widgets/ukui-task-manager/qml/AppIcon.qml:188-194`; same pattern in every widget.

**Taskbar buttons** (`widgets/ukui-task-manager/qml/AppIcon.qml`):
- **Icon-only and grouped by app**, dock-like; there are no text labels in the default mode. A list mode (`AppList.qml`) with labels exists for non-merged windows.
- Item size 48 (`AppList.qml:40`), background inset 4·r (`AppIcon.qml:39`), icon inside that with the same inset.
- **Running indicator:** a pill 4·r high and `min(windows·8, 16)·r` wide (1 window = 8, 2+ = 16), radius 2·r, centered on the **bottom edge** of the tile.
  - Color is `kBrandNormal` when the app owns the active window, else gray Alpha9 (black 0.30).
  - Width animates over 200 ms. Source: `AppIcon.qml:310-322`.
- **Demands attention:** orange `#FF9100` fill under the icon, opacity pulsing 0.25↔0.6, 450 ms × 4 loops (`AppIcon.qml:238-254`).
- **Unread badge:** red (`kErrorNormal`) circle, ½ the icon height, at the top-right offset −3, white count, "99+" cap (`AppIcon.qml:262-306`).
- Press scales the icon over a 100 ms animation (`AppIcon.qml:258-261`).
- **Hover preview** (`ThumbnailWindow.qml:41-64`):
  - window thumbnail 272×192 (content 240 wide), margin 8 from the panel and 8 from screen edges
  - one card per window with its title and a close button
  - radius `kRadiusWindow` (12) (`TaskManagerView.qml:222`)
  - pinned apps with no window get a plain tooltip instead
- **Right-click on a task button** (`widgets/ukui-task-manager/task-manager-item.cpp:342-387`): recent files → the app's desktop actions → *App name* (new instance) → Remove from / Add to panel → Close.
  - Thumbnail cards add Close, Restore, Maximize, Minimize, Keep above (`ukui-task-manager.cpp:825-845`).

**Clock** (`widgets/ukui-panel-calendar`):
- **Two lines**: `HH:mm Weekday` over `yyyy/MM/dd`. The separator is "/" for the cn format and "-" otherwise (`plugin/calendar.cpp:43,130,190-245`; `widget/ui/*.qml:160-195`).
- Text is vertically fitted to the panel height.
- Tile width is content + 8 (`widget/ui/*.qml:260`).
- Tooltip shows the long date. Click opens the calendar popup.

**Panel right-click** (`panel.cpp:755-834`), in order:
1. "Show Search" / "Show Task View" toggles
2. separator
3. Show Desktop
4. System Monitor
5. separator
6. Panel Size ▸ (Large / Medium / Small / Custom)
7. Panel Position ▸ (Top / Bottom / Left / Right)
8. Lock Panel
9. Auto Hide
10. Switch to New Panel
11. separator
12. Panel Setting

**Alternative "three-island" panel (`org.ukui.panelNext`)** (README; `panel/qml/org.ukui.panelNext`):
- floating rounded bottom islands for data, apps and settings
- smart-hide, and it does not reserve screen space
- optional 32px top bar (`org.ukui.panel.settings.gschema.xml:46-47`)

**Not the default** (`paneltype` default 0 = classic, gschema :28-29). Port the classic panel first.

---

## 3. Start menu (ukui-menu)

The **"window" mode is the default** (`full-screen` false).

| Property | Value | Source |
|---|---|---|
| Size | **766 × 688** (user range 766–900 × 688–700) | `ukui-menu/data/org.ukui.menu.settings.gschema.xml:9-17` |
| Placement | bottom-left, 8 from the screen and panel edges (`margin` 8); follows the panel edge | gschema :21-28; `src/windows/menu-main-window.cpp:340-405` |
| Shape | radius 12, 1px line, translucent `windowActive` × 0.65 with blur | `qml/mainXcb.qml:104-114` |
| Show animation | slides in from the panel edge (Wayland `slideWindow`); normal ↔ full-screen morph animates geometry over 300 ms, bezier (0.25, 0.1, 0.25, 1); content fades in with InQuint | gschema :4-5; `mainXcb.qml:118-207` |

**Columns, left to right** (`qml/AppUI/NormalUI.qml:56-92`):

| Column | Width | Contents |
|---|---|---|
| App list | **312** | search 40 high at top (margins 12 top, 16 sides), then a scrolling list |
| Divider | 1 | |
| Widget page | ~396 | 32-high tab bar ("Favorites", "Recent"); favorites grid with cells 88×100, 48 icons, radius 8 |
| Divider | 1 | |
| Sidebar | **56** | 36×36 buttons, radius 4, spacing 4 |

- App list rows (`AppListView.qml:34,94`; `AppItem.qml:29-41`): **40 high**, 32 icon, spacing 4, radius 4, hover/press = contain-alpha.
- The **sidebar** buttons run top to bottom: full-screen toggle, spacer, **User, Computer, Settings, Power** (`qml/AppUI/Sidebar.qml:36-262`).
- **Search bar** (`SearchInputBar.qml:32-121`):
  - fill black 0.02, 1px border (brand when focused)
  - placeholder "Search App", which slides left over 100 ms on focus
- **List modes:** All (default), Letter (A–Z headers), Category (`app-list-display-mode`, gschema :37-38).
  - Categories: AudioVideo, Audio, Video, Development, Education, Game, Graphics, Network, Office, Science, Settings, System, Utility, Other (`src/libappdata/app-category-model.cpp:31-44`).
  - Group headers are 36 high and bold. Clicking a header opens a jump grid (200 wide, 40 cells).
- **Power menu** (`src/utils/power-button.cpp:81-148`): Lock Screen, Suspend, Hibernate, Shut Down, Restart.
- **Keyboard:** typing any letter or digit focuses search; Esc closes; opening clears the query (`NormalUI.qml:20-36`; `mainXcb.qml:38-42`). Super alone toggles the menu (kwin modifier-only shortcut → `org.ukui.menu`, `kwin/src/options.cpp:749`).
- **App right-click** (`src/extension/menu/app-menu-plugin.cpp:41-195`): Fix to / Unfix from all apps (pin to top), Add to / Remove from taskbar, Send to desktop shortcuts, separator, Clear recent-install mark, Uninstall. Favorites also offers Fix to / Remove from favorite. A "recently installed" item has an 8px accent dot.
- **Full-screen mode** (`FullScreenUI.qml`, `FullScreenAppList.qml:37-47`):
  - wallpaper blur (BlurWallpaper)
  - search box 372×36 at the top
  - category column 120 wide
  - grid of 160 tiles, `cols = clamp(ceil(((4+2560/W)·W/8)/188), 1, 9)`, icon at 0.6 of the tile
  - round 48 power button in the footer

---

## 4. Window decoration (kwin `UKUI` KDecoration2 plugin)

All values are from `kwin/src/plugins/kdecorations/ukui/ukui-decoration.cpp` unless noted. Values are scaled by DPI/96.

| Property | Desktop | Tablet mode | Line |
|---|---|---|---|
| Title bar height | **38** | 64 (48 for modal windows) | 129-132 |
| Side and bottom borders | 0 (resize is handled through the shadow and a 13px cursor zone) | — | 43, 128-134 |
| Caption buttons (min, max, close) | **30 × 30**, spacing 4, top margin 4, right margin 4 | 48×48, spacing 0 | 136-167, 589-602 |
| App icon (left, "menu" button) | 24×24 at x=8, y=8 | 32×32 | 147-157, 593 |
| Title text | left-aligned after the icon, vertically centered, **middle-elided**, system font (10pt) regular | — | 553-563 |
| Corner radius | top **12** (`RADIUS`, or `windowRadius` from gsettings); **bottom corners squared off** by the frame paint, the client rounds its own content via the "ubr" effect; 0 when maximized or edge-snapped | — | 46, 221-235, 528-547 |

**Frame colors** (:78-80, 502-512):

| State | Light frame | Light text | Dark frame | Dark text |
|---|---|---|---|---|
| Active | `#FFFFFF` | `#262626` | `#121212` | `#CFCFCF` |
| Inactive | `#F5F5F5` | `#262626` at alpha 0.3 | `#1C1C1C` | `#CFCFCF` at alpha 0.3 |

The inactive text alpha is set in `fontColor()` at :604-614.

**Outline and shadow** (:48-54):
- Outline: 1px, black 0.15 (white 0.15 in dark).
- Shadow, active: blur 38, y-offset 22, black 0.60.
- Shadow, inactive: blur 25, y-offset 15, black 0.40.
- For the visual target use the token shadows (§1.5); the decoration constants are the raw blur parameters.

**Button order:** `[app icon] Title ……… [–] [□] [×]`, right-aligned (KDE default `M:IAX`). Buttons the window does not allow are hidden (`button.cpp:44-66`).

**Caption button art** (`icon/ukui-base/*.svg`; copies are in `ref/decoration/`):
- Each glyph is a 1px line with round caps, about 10px wide, centered in the 30 box.
- Minimize is a horizontal bar. Maximize is a rounded square. Restore is two overlapped squares. Close is an ×.

| State | Min / Max (light) | Min / Max (dark) | Close |
|---|---|---|---|
| Normal | glyph `#262626`, no background | glyph white, no background | glyph `#262626` (white in dark), no background |
| Hover | rounded rect r6, **black 0.16** | white 0.20 | **`#E7202B`** r6, glyph white |
| Pressed | black 0.21 | white 0.30 | **`#C21B24`**, glyph white 0.75 |
| Inactive window | glyph black 0.3 (`ukui-base-inactive`) | | |

**Title-bar mouse behavior** (`kwin/src/kwin.kcfg`):

| Input | Action | Line |
|---|---|---|
| Double-click | maximize / restore | :182 |
| Left click | raise | :17 |
| Middle click | nothing | :20 |
| Right click | window menu | :23 |
| Maximize button, middle click | vertical maximize | :185-193 |
| Maximize button, right click | horizontal maximize | :185-193 |
| Window drag modifier | **Meta** (not Alt) | :11 |

**Window menu** (`kwin/src/useractions.cpp:257-358`):
1. Maximize
2. Minimize
3. More Actions ▸ (Move, Resize, Keep Above, Keep Below, Fullscreen, Shade, No Border, Window Shortcut…, Special Settings…)
4. Close

Client-side-decorated UKUI apps (peony, ukui-control-center) draw the same 30×30 buttons with spacing 4 themselves (`peony/src/control/header-bar.cpp:1215-1258`).

---

## 5. Multitask view (task view) and Alt+Tab, `ukui-window-switch`

**Trigger:** the taskbar task-view button or **Meta+Tab** (`windowsview/ukui-window-switch-kwineffect/multitaskviewmanager.cpp:421`). Esc closes it.

**Layout** (`qml/MultitaskView.qml:32-165`), PC "vertical" variant:
- Black background with the wallpaper dimmed.
- **Window thumbnails** fill the top 111/135 of the screen: rows centered, spacing 16 vertical and 10 horizontal, thumbnail height H·5/22.
- Each thumbnail has a title row with icon and close button (32 high), outer radius 12 and inner radius 8. Hover gets a white border, keyboard focus a brand border (`AppPreviewWindow.qml:142-208`).
- **Workspace strip** along the bottom 24/135, on a white `kContainGeneralNormal` bar:
  - workspace cards are 16/135 of the screen height, spacing 24, titled "Desktop N", each with a circular close button
  - a trailing **"New Desktop"** card has a 32 "+"
  - dragging a window onto a card moves it to that workspace
  - Sources: `DesktopArea.qml:34-44,331-339`; `VirtualDesktopWindow.qml:256-337`; `NewDesktopButton.qml:140-177`
- **Animations:** workspace add/remove scales and fades over 300–400 ms InOutQuad. Window reflow takes 500 ms. Titles fade over 300 ms InOutQuart.

**Alt+Tab** (`Tabbox.qml:45-218`):
- A centered strip of window thumbnails, each up to (W−40)/4 wide with height H·5/22, a 24 icon and a title.
- Panel background `kComponentNormal` × transparency, 1px line, radius 12.
- The selected item gets a **2px `KFont-Primary` outline**, radius 12.
- Alt+\` walks windows of the current app (`kwin/src/tabbox/tabbox.cpp:546-549`).

**Workspaces:**
- Switch with Ctrl+Meta+←/→ (also Ctrl+Alt+←/→) or Ctrl+F1…F4 (`kwin/src/virtualdesktops.cpp:846-870`).
- Overview effect: Meta+W (`effects/overview/overvieweffect.cpp:33`).

---

## 6. Sidebar: quick settings and notification center (`ukui-sidebar`)

There are **two separate surfaces.** In UKUI 4 the notification center and the popups are both drawn by `ukui-sidebar`.

| | Quick-settings window (from the panel tray) | Notification center (right edge) |
|---|---|---|
| Size | 396 wide (540 tablet) | 384 content + 8 padding on each side; full height minus the panel |
| Placement | 8 from the panel, slides out from the panel edge | right edge |
| Radius | 12 | 12 |
| Background | translucent and blurred | `kContainSecondaryNormal` + blur, 1px line, 16 inner margins, primary shadow |
| Content | **toggle grid** of 4 columns, tiles 80×72, gap 12, radius 8, 24 icons; "menu" toggles span 2 columns (172 wide) with a 48 circular icon. **Sliders** (volume, brightness) are 356×56 rows with a 24 icon and a 16-high fully rounded track. Section spacing 16 | notification cards grouped by app |
| Open / close | 300 ms slide | slide x from 392 → 0 over **300 ms InOutQuad**, blur fades with it; gestures scale the duration (min 50 ms) |
| Shortcut | — | **Super+A** (`ukui-settings-daemon/data/org.ukui.SettingsDaemon.plugins.media-keys.gschema.xml:204`) |

Sources:
- Quick settings: `qml/Shortcuts.qml:41,292`; `src/windows/shortcuts-window.cpp:222-310`; `EditShortcutFlow.qml:32-85`; `ShortcuPanel.qml:221-446`; `ProgressBar.qml`.
- Notification center: `src/windows/sidebar-view.cpp:43,280-307`; `qml/Sidebar.qml:28-258`; `NotificationArea.qml:26-39`.

---

## 7. Notification popups

Drawn by `ukui-sidebar`; `PopupView.qml` and `PopupNotificationItem.qml`.

**Placement and card:**
- Top-right corner, 374 wide, 8 from the screen edges, 8 between stacked popups.
- When the sidebar is open, popups shift left by its width.
- Card: radius 8, padding 16, 1px line.
  - **Header row** (24): app icon + app name (secondary color) + time + 24 round close button.
  - **Title and body:** up to 2 lines each, indented 32.
  - **Action row:** 36 high, buttons 98 wide, radius 6.
- Several popups from one app fold into "%1 more notifications".

**Timeouts** (`ukui-notification/libukui-notification/popup-notification.cpp:58,391-443`):

| Urgency | Behavior |
|---|---|
| Default | 6000 ms |
| Low | never pops up |
| Critical | sticky |

**Animations:**

| Event | Animation |
|---|---|
| Enter | slide x 374 → 0, 300 ms InOutQuad |
| Reflow | 220 ms, bezier (0.25, 0.1, 0.25, 1) |
| Dismiss | scale 0.8 + fade, 260 ms |

---

## 8. Apps used as references

### Peony (file manager → our Files app)

| Item | Value | Source |
|---|---|---|
| Window | 2/3 × 4/5 of the screen, min 850×525 | `peony/libpeony-qt/global-settings.cpp:344-349` |
| Client-side header | **60** high (72 tablet) | `src/windows/main-window.cpp:2339-2342` |
| Sidebar | **292** wide (min 144), translucent at 0.65 like the nav panes | `global-settings.cpp:352`; `org.ukui.style` gschema :46-47 |
| Header row | Back, Forward, (Up), 9px gap, then the path bar with an inline search toggle (expanding), then the options menu (`open-menu-symbolic`), then the window buttons. Icons 16. View-type and sort buttons were removed in 4.x and live in the options menu | `header-bar.cpp:110-398` |
| Default view | Icon view, zoom 70 → icon 39+70 = **~109 px** (range 64–139); list view icon 16–40, rows 36 | `icon-view.cpp:1610-1617`; `list-view.cpp:2038-2041` |
| Icon cell | (icon+37) × (icon + 2 text lines + 30), grid +20 | `icon-view-delegate.cpp:91-94` |
| Tabs | in-window tab bar with a "+" button (30×30) | `src/control/tab-widget.cpp:234-252` |
| Preview pane | min 300 wide | `tab-widget.cpp:199` |

### Desktop (peony-qt-desktop → DesktopSurface)

**Icon presets** (`peony-qt-desktop/common.h:63-68`). The default icon is 64 (`file-action-controler.h:167`).

| Preset | Icon | Grid |
|---|---|---|
| Small | 24 | 64×64 |
| Normal | 48 | 96×96 |
| Large | 64 | 115×135 (default) |
| Huge | 96 | 140×170 |

- Labels show two lines with ellipsis.
- Single click selects; double-click opens.

**Desktop right-click** (`peony-qt-desktop/desktop-menu.cpp:105-141`):
1. Open Desktop in Window
2. separator
3. Auto Arrange
4. View Type ▸
5. Sort By ▸ (Name / Modified / Type / Size, ascending or descending)
6. Refresh
7. separator
8. New ▸
9. separator
10. Paste, Undo / Redo, Select All
11. separator
12. Background Settings, Display Settings
13. separator
14. Properties

### Control Center (→ Settings)

| Item | Value | Source |
|---|---|---|
| Window | 1160×720 (min 978×630) | `ukui-control-center/shell/mainwindow.cpp:242-244` |
| Left nav | **260** wide, translucent; items **230×40**, radius 6, selected = accent fill with white text | `mainwindow.cpp:853-940,1062` |
| Title bar | 40, search box 240×36 | `mainwindow.cpp:480-547` |
| Content | settings are grouped **cards of rows**: rows ≥ **60 high**, 16 side padding, 1px gaps between rows, radius 6 on the group's outer corners only (`KGray-1/2` card on a `KGray-0` page) | `libukcc/widgets/SettingWidget/ukccframe.cpp:38-41`; `settinggroup.cpp:7` |
| Switch | 50×24 pill in accent | `SwitchButton/switchbutton.cpp:32-41` |
| Home page | flow of module cards ≥ 300×97, 48 icon, title plus sub-links | `shell/homepagewidget.cpp:72-171` |

**Modules** (`libukcc/interface/interface.h:36-49`): Account, System, Devices, Network, Personalized, Datetime, Update, Security, Application, Search.

---

## 9. Icons, cursors, wallpaper, sound

| Asset | Name | Where | License |
|---|---|---|---|
| Icon theme (default) | **`ukui-icon-theme-default`**, displayed as "光", ~14.6k files, scalable SVG + 8–256 PNG; `Inherits=gnome,hicolor,Adwaita`; colourful rounded-square app icons, flat 16px symbolic actions | Debian `ukui-icons-theme_4.0.0.1-1_all.deb` (80 MB); older copy at `src/ukui-theme/icons/ukui` | Debian copyright: **GPL-3**. `index.theme` says "from moka" (Moka icons are CC-BY-SA-4.0 / GPL-3 dual), so keep attribution |
| Other icon themes | `ukui-icon-theme-classical`, `-fashion` | same deb | **do not bundle** (size) |
| Cursor | **`dark-sense`** (default, black); `blue-crystal` (X cursors, 1.8 MB) | same deb; `src/ukui-theme/dark-sense` | GPL-3 |
| GTK theme | **`ukui-white`** (light) / **`ukui-black`** (dark), GTK 2 + 3 only, no GTK 4 | Debian `ukui-gtk-theme_4.0.0.1-1_all.deb` (215 KB) | GPL-3 |
| Qt widget style | `qt5-ukui-platformtheme` (style "ukui", palettes ukui-light/ukui-dark) | not buildable on Alpine without kysdk/peony deps; use Kvantum (see guest-install.md) | LGPL/GPL |
| Wallpaper | default `/usr/share/backgrounds/1-openkylin.jpg` (`theme.conf:wallPaperPath`); carries openKylin branding, **do not ship**. Debian `ukui-wallpapers` 20.04.4 (CC-BY-SA-3.0) has neutral ones: `sea.jpg`, `mountain-range.jpg`, `fluent-color.png`. Or draw our own "Light-Seeking"-like blue gradient with a soft wave (see `ref/globaltheme-Light-Seeking.png`) | | CC-BY-SA-3.0 |
| Sound theme | Light-Seeking | Debian `ukui-sounds-theme` | skip |

**Bundling for the native shell.** Only the icon cache matters to the shell; it is produced by `ish-apply-style`. Bundle `ukui-icon-theme-default` without the `@2x` PNG directories, plus `dark-sense`. Ship `/usr/share/ish/themes/licenses/ukui-icons-theme.copyright`.

**Trademarks.** Do not use:
- `kylin-startmenu` (the Kylin and openKylin logo, also seen in `ref/` previews)
- the "Kylin" / "openKylin" names in UI strings
- `1-openkylin.jpg`
- the 方正 font

**Neutral start glyph:** SF Symbol `circle.hexagongrid.fill` in kbrand1 (`#3790FA`) on the starter tile. If a custom asset is preferred: a four-petal rounded-square knot in the brand gradient (`#3790FA` → `#06C0C7`), 24pt. Call the style "Kylin-like" internally and **"Lumen"** (or similar) in the UI if trademark caution is wanted.

---

## 10. Interaction logic

| Context | Behavior | Source |
|---|---|---|
| Desktop icon | single click selects; double-click opens; drag to rearrange (auto-arrange option) | standard Qt view behaviour in peony-qt-desktop; the click handling was not traced line by line |
| Taskbar, app with no window | click launches | `ukui-panel/widgets/ukui-task-manager/qml/TaskManagerBase.qml:335-337` |
| Taskbar, app with a window | click activates the window; clicking the active one minimizes it | `TaskManagerBase.qml:248-254` |
| Taskbar, app with >1 window | each click activates the **next** window in turn | `TaskManagerBase.qml:340-350` |
| Taskbar hover | thumbnails (tooltip for pinned apps with no window) | `ThumbnailWindow.qml` |
| Taskbar middle-click | not handled (left and right buttons only) | `TaskManagerBase.qml:224-232` |
| Taskbar, new instance | the app-name item in the right-click menu | `task-manager-item.cpp:360` |
| Title bar | double-click maximizes; drag moves; drag to the top edge (within 5px) **maximizes**; drag to the left or right edge (within 20px) **half-tiles**; edge plus top or bottom 25% **quarter-tiles**; window/edge snap zones 10px | `kwin/src/abstract_client.cpp:2476-2499`; `kwin.kcfg:147-178` |
| Meta+Arrows | cyclic tiling state machine (Normal → half → quarter …; Up = maximize; Down = restore) | `kwin/src/placement.cpp:921-962` |
| Super (tap) | toggle start menu | `kwin/src/options.cpp:749` |

**Keyboard shortcuts** (`ukui-settings-daemon/.../media-keys.gschema.xml`, cited as SD; `kwin/src/useractions.cpp`, cited as UA):

| Keys | Action | Source |
|---|---|---|
| Super | start menu | |
| Super+Tab | multitask view | |
| Super+D | show desktop | UA:1095 |
| Super+M | minimize all | UA:1099 |
| Super+E | file manager | SD:99 |
| Super+I | settings | SD:89 |
| Super+A | sidebar | SD:204 |
| Super+S | search | SD:229 |
| Super+L | lock | SD:84 |
| Super+V | clipboard | SD:244 |
| Ctrl+Alt+T or Super+T | terminal | SD:169,174 |
| Alt+Tab / Alt+\` | switch windows / switch within the app | |
| Alt+F4 | close | |
| Alt+F10 | maximize | |
| Alt+F9 | minimize | |
| Alt+F3 | window menu | |
| Meta+←/→/↑/↓ | tile | |
| Ctrl+Meta+←/→ or Ctrl+Alt+←/→ | switch workspace | |
| Ctrl+F1…F4 | go to workspace N | |
| PrtSc / Shift+PrtSc / Ctrl+PrtSc | screenshot full / area / window | SD:179-199 |
| Ctrl+Shift+Esc | system monitor | SD:219 |
| Ctrl+Alt+Del | logout dialog | SD:54 |

Hot corners: none by default (`kwin.kcfg:58-81`).

---

## 11. Mapping to DesktopKit

Proposed `DesktopStyleSpec.kylin`:

```
shell: .taskbar, dockEdge: nil, buttonPlacement: .trailing, buttonShape: .kylin /* new: r6 hover tile, red close */,
centersTitle: false, launcher: .startMenu, overviewSearches: false, cornerRadius: 12,
accent: #3790FA,
titleBarActive: #FFFFFF, titleBarInactive: #F5F5F5,            // dark: #121212 / #1C1C1C
panelBackground: #F6F6F6 @0.65 + .ultraThinMaterial,            // dark: #2E2E2E @0.65
windowBackground: #F6F6F6 (window) / #FFFFFF (content),         // dark: #2E2E2E / #1E1E1E
topBarHeight: 0, bottomBarHeight: 48, dockThickness: 0
```

The existing four specs are dark-first. **Kylin's default variant is light** (`theme.conf` `defaultLightDarkMode=light`), so `DesktopTheme` needs a light palette for this style.

| UKUI element | DesktopKit component | Change |
|---|---|---|
| ukui-panel classic, 48, bottom | `PanelView` / `StyledShell` taskbar | Full-width 48pt bar with frosted `#F6F6F6`@0.65 and no top hairline. Left group: start tile, search tile, task-view tile, 1px separator (24 high), icon-only grouped task buttons (40×40 tile in a 48 cell, r6), all with leading margin 8 and spacing 4. Right group: status icons, two-line clock (`HH:mm EEE` / `yyyy/MM/dd`), 17pt show-desktop strip. Running pill 4×8/16 at the bottom edge, accent when active. Hover 0.15, press 0.20 black overlay. |
| Task thumbnails | `PanelView` hover popover | 272×192 cards, r12, title and close; tooltip for pinned apps with no window |
| ukui-menu window mode | `LauncherView` / `Launchers.swift` (.startMenu) | 766×688, bottom-left, 8 from the edges, r12, frosted. Three columns: 312 app list (40pt rows, 32 icons, r4) with a 40 search field; ~396 Favorites/Recent tabs (88×100 cells, 48 icons); 56 sidebar (User, Computer, Settings, Power; 36 buttons). Type-to-search, Esc closes, 300 ms slide from the panel edge. Optional full-screen toggle reusing `.fullScreenGrid` |
| kwin UKUI decoration | `WindowView` chrome + `WindowButtons.swift` | Title bar 38 (**use the tablet value 48–64 when there is no pointer**). Left 24 app icon, left-aligned middle-elided title in 14 regular `#262626` (alpha 0.3 inactive). Right: 30×30 min/max/close, spacing 4, inset 4. Hover r6 black 0.16; close hover `#E7202B`, pressed `#C21B24`. Window r12, 1px black 0.10 outline, shadow y22 blur38 black 0.30 (inactive y15 blur25 0.20). Double-click maximizes; drag to the edges tiles (`TilingControls`) |
| Alt+Tab Tabbox | `WindowSwitcher` | Horizontal thumbnail strip, frosted r12 panel, selected item gets a 2px primary-text outline r12; Alt+\` for the same app |
| Multitask view | `Overview` | Dimmed black background; window grid in the top ~82%; bottom workspace strip with "Desktop N" cards (r12) and a "+ New Desktop" card; drag a window onto a desktop. Super+Tab |
| peony-qt-desktop | `DesktopSurface` / `DesktopIcons.swift` | Large preset (64 icon, 115×135 grid), 2-line labels, single click selects, double-click opens; desktop menu as in §8 |
| Control center | Settings app | 260 frosted nav with 230×40 r6 items (accent selected); content as grouped cards of 60pt rows, 16 padding, 1px gaps, outer r6; 50×24 switches |
| Notification popups | `ToastStack` | Top-right, 374 wide, r8, padding 16, header row (icon, app, time, close), 2-line title and body, 6 s timeout; enter slide 300 ms InOutQuad; exit scale 0.8 + fade 260 ms |
| Sidebar / quick settings | (new) panel tray popover + right-edge `NotificationCenter` | Quick settings: 396 wide, 4-column 80×72 toggles r8, 56-high slider rows. Notification center: 384 wide, r12, slides in over 300 ms. Super+A |
| Peony | `FilesApp` | 60pt header (back, forward, path bar with inline search, options menu); 292 frosted sidebar; icon view at ~96–109 icons by default; tabs; list rows 36 |
| Tokens | `DesktopTheme` | Add the §1 tokens: radii 4/6/8/12, alpha ramp, KGray ramp light and dark, 9 accents, 150 ms default and 300 ms shell motion, transparency 0.65 |

---

## 12. Reference images (`themes/kylin/ref/`)

| File | Shows | Source |
|---|---|---|
| `globaltheme-Light-Seeking.png` / `-v11.png` (identical) | default look: frosted bottom panel with icons, frosted r12 start menu (two panes), window with a frosted nav pane, a brand-blue selected item, and white content | `ukui-globaltheme/globaltheme/*/preview.png` |
| `globaltheme-Classic.png` | square-cornered variant | same |
| `globaltheme-HeYin.png` | purple variant | same |
| `custom-preview.png` | custom theme template | same |
| `classic.png`, `island.png` | panel mode thumbnails | `ukui-panel/panel/ukcc-plugin/resource/` |
| `decoration/ukui-base/*.svg` | exact caption-button art | kwin |

The previews include the openKylin logo, so they are reference only and must not be shipped.
