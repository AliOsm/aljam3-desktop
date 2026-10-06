on run argv
    set mountPath to item 1 of argv
    set screenshotPath to item 2 of argv
    tell application "Finder"
        activate
        set imageFolder to (POSIX file mountPath) as alias
        open imageFolder
        delay 2
        tell container window of imageFolder
            if current view is not icon view then error "Install window is not in icon view"
            if toolbar visible then error "Install window toolbar should be hidden"
            if icon size of icon view options is not 104 then error "Icon size was not saved"
        end tell
        if position of item "Aljam3.app" of imageFolder is not {162, 202} then error "App icon position was not saved"
        if position of item "Applications" of imageFolder is not {478, 202} then error "Applications icon position was not saved"
        do shell script "/usr/sbin/screencapture -x " & quoted form of screenshotPath
        close container window of imageFolder
    end tell
end run
