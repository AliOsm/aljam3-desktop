on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        set imageFolder to (POSIX file mountPath) as alias
        set imageFolder to disk (name of imageFolder)
        open imageFolder
        delay 1
        tell container window of imageFolder
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set bounds to {200, 160, 840, 582}
        end tell
        set options to the icon view options of container window of imageFolder
        set arrangement of options to not arranged
        set icon size of options to 104
        set text size of options to 14
        set background picture of options to file ".background:background.tiff" of imageFolder
        set position of item "Aljam3.app" of imageFolder to {162, 202}
        set position of item "Applications" of imageFolder to {478, 202}
        update imageFolder without registering applications
        delay 3
        close container window of imageFolder
        delay 1
    end tell
end run
