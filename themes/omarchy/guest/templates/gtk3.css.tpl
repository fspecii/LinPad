/* linpad-colors: written by ish-apply-colors; `ish-apply-colors none` removes it. */
/* Recolours the current style's GTK theme with a colour theme; shapes stay the style's. */
@define-color theme_bg_color {{ background }};
@define-color theme_fg_color {{ foreground }};
@define-color theme_base_color {{ dark_background }};
@define-color theme_text_color {{ foreground }};
@define-color theme_selected_bg_color {{ accent }};
@define-color theme_selected_fg_color {{ background }};
@define-color theme_unfocused_bg_color {{ background }};
@define-color theme_unfocused_fg_color {{ foreground }};
@define-color insensitive_fg_color {{ muted }};
@define-color borders {{ mix background foreground 15% }};
@define-color accent_color {{ accent }};
@define-color accent_bg_color {{ accent }};

window, .background, dialog, assistant, notebook > stack, notebook > header, statusbar {
  background-color: {{ background }};
  color: {{ foreground }};
}
.view, iconview, textview text, treeview.view, list, row, .sidebar, placessidebar, scrolledwindow viewport {
  background-color: {{ dark_background }};
  color: {{ foreground }};
}
headerbar, .titlebar, menubar, toolbar, .toolbar, actionbar, searchbar {
  background-color: {{ lighter_background }};
  background-image: none;
  color: {{ foreground }};
  border-color: {{ mix background foreground 15% }};
  box-shadow: none;
}
button, combobox button, spinbutton button, .linked button {
  background-color: {{ lighter_background }};
  background-image: none;
  color: {{ foreground }};
  border-color: {{ mix background foreground 15% }};
  box-shadow: none;
  text-shadow: none;
}
button:hover { background-color: {{ mix lighter_background foreground 8% }}; }
button:active, button:checked { background-color: {{ mix lighter_background foreground 22% }}; }
button.suggested-action, button.default {
  background-color: {{ accent }};
  color: {{ background }};
}
entry, spinbutton, textview, .entry {
  background-color: {{ dark_background }};
  background-image: none;
  color: {{ foreground }};
  border-color: {{ mix background foreground 15% }};
}
entry:focus, spinbutton:focus { border-color: {{ accent }}; }
selection, *:selected, row:selected, treeview.view:selected, iconview:selected, textview text selection,
entry selection, label selection {
  background-color: {{ selection }};
  color: {{ selection_foreground }};
}
menu, .menu, .context-menu, popover, popover.background, popover > contents, tooltip, tooltip.background {
  background-color: {{ lighter_background }};
  color: {{ foreground }};
  border-color: {{ mix background foreground 15% }};
}
menuitem:hover, modelbutton:hover, popover modelbutton:hover { background-color: {{ selection }}; color: {{ selection_foreground }}; }
check:checked, radio:checked, check:indeterminate, radio:indeterminate, switch:checked,
progressbar progress, scale highlight, scale trough highlight, levelbar block.filled {
  background-color: {{ accent }};
  background-image: none;
  border-color: {{ accent }};
  color: {{ background }};
}
switch slider, scale slider {
  background-color: {{ foreground }};
  background-image: none;
  border-color: {{ mix background foreground 15% }};
}
*:link, link, button.link { color: {{ accent }}; }
*:disabled, label:disabled { color: {{ muted }}; }
separator { background-color: {{ mix background foreground 15% }}; }
