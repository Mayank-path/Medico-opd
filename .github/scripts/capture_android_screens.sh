#!/bin/bash
set -e

echo "=== Android Screenshot Capture Pipeline ==="

adb wait-for-device
adb install build/app/outputs/flutter-apk/app-debug.apk
adb forward tcp:8888 tcp:8888
adb shell am start -n com.medico.opd.medico_opd/.MainActivity

echo "=== Step 1: Awaiting ClinicProfileScreen ==="
for i in $(seq 1 45); do
  STATUS=$(curl -s --connect-timeout 2 -m 3 http://127.0.0.1:8888/status || true)
  echo "Attempt $i: App status is '$STATUS'"
  if [ "$STATUS" = "clinic_profile" ]; then break; fi
  sleep 2
done
sleep 2
echo "Capturing screenshot_clinic_profile_android.png..."
adb exec-out screencap -p > screenshot_clinic_profile_android.png

echo "=== Step 2: Advancing to PatientListScreen ==="
curl -s -m 5 http://127.0.0.1:8888/next || true
for i in $(seq 1 30); do
  STATUS=$(curl -s --connect-timeout 2 -m 3 http://127.0.0.1:8888/status || true)
  echo "Attempt $i: App status is '$STATUS'"
  if [ "$STATUS" = "patient_list" ]; then break; fi
  sleep 1
done
sleep 2
echo "Capturing screenshot_patient_list_android.png..."
adb exec-out screencap -p > screenshot_patient_list_android.png

echo "=== Step 3: Advancing to ConsultationHistoryScreen ==="
curl -s -m 5 http://127.0.0.1:8888/next || true
for i in $(seq 1 30); do
  STATUS=$(curl -s --connect-timeout 2 -m 3 http://127.0.0.1:8888/status || true)
  echo "Attempt $i: App status is '$STATUS'"
  if [ "$STATUS" = "consultation" ]; then break; fi
  sleep 1
done
sleep 2
echo "Capturing screenshot_consultation_android.png..."
adb exec-out screencap -p > screenshot_consultation_android.png

ls -lh screenshot_*android.png
echo "=== Android Screenshot Capture Complete ==="
