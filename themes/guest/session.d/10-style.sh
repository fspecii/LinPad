# Sourced by ishwl-session. Qt apps follow the GTK settings that ish-apply-style writes
# (fonts, icon theme, palette, through Qt's gtk3 platform theme) and draw their widgets
# with Kvantum, whose theme ish-apply-style also selects. The cursor theme only matters
# to apps that draw their own cursor; the iOS pointer is native.
if [ -d /usr/share/ish/themes/styles ]; then
    export QT_QPA_PLATFORMTHEME=gtk3
    [ -e /usr/lib/qt5/plugins/styles/libkvantum.so ] && export QT_STYLE_OVERRIDE=kvantum
    if [ -r /usr/share/ish/current-style.env ]; then
        while IFS='=' read -r key value; do
            case $key in XCURSOR_THEME|XCURSOR_SIZE|ISH_STYLE|ISH_STYLE_VARIANT) export "$key=$value";; esac
        done < /usr/share/ish/current-style.env
    fi
fi
