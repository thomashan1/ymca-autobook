#!/bin/sh
# Runs inside the macOS 12 VM, from the test disk scripts/test_macos12.sh attaches
# as /Volumes/YBTEST. Each step appends to results.txt there for the host to read.
#   sh /Volumes/YBTEST/guest.sh install|sample|count|stop
V=/Volumes/YBTEST
R="$V/results.txt"
APP="/Applications/YMCA Booker.app"
copies() { pgrep -x "YMCA Booker" | wc -l | tr -d ' '; }

case "$1" in
install)
  killall "YMCA Booker" 2>/dev/null; sleep 2
  M="$(hdiutil attach -nobrowse -readonly "$V"/*.dmg | awk -F'\t' '/\/Volumes\// {print $NF}')"
  rm -rf "$APP" && ditto "$M/YMCA Booker.app" "$APP"
  hdiutil detach "$M" -quiet
  {
    echo "macos=$(sw_vers -productVersion)"
    echo "build=$(defaults read "$APP/Contents/Info" CFBundleVersion)"
  } > "$R"
  open -a "$APP"; sleep 15
  echo "copies_after_install=$(copies)" >> "$R"
  ;;
sample)
  # The app's own screenshot mode: sample data, each tab saved as a PNG, then it quits.
  killall "YMCA Booker" 2>/dev/null; sleep 2
  # Saved locally first: the app would have to ask before writing to the test disk.
  rm -rf /tmp/yb-shots "$V/shots"; mkdir -p /tmp/yb-shots "$V/shots"
  open -W -a "$APP" --args -sampleData YES -screenshotDir /tmp/yb-shots
  cp /tmp/yb-shots/*.png "$V/shots/"
  echo "shots=$(ls "$V/shots" | tr '\n' ' ')" >> "$R"
  # Running again, so the restart that follows reopens it as well as the login item.
  open -a "$APP"; sleep 10
  ;;
count)
  sleep 5
  echo "copies_after_restart=$(copies)" >> "$R"
  echo "login_item=$(plutil -extract ProgramArguments.0 raw ~/Library/LaunchAgents/com.thomashan.ymcaautobook.login.plist 2>/dev/null)" >> "$R"
  ;;
stop)
  sync
  echo test | sudo -S shutdown -h now
  ;;
esac
