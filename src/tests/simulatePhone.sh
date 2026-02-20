LAN=verifier.local
BASE="https://${LAN}:8443"

echo "Start Session for Phone A"
# Simulate Phone A (HospitalA-admin)
PHONE_A=$(curl -sk \
  --cert ../vfp-governance/verifier/certs/HospitalA-admin.crt \
  --key  ../vfp-governance/verifier/certs/HospitalA-admin.key \
  "${BASE}/verify-start")
echo "Phone_A 6-digits code: $PHONE_A"

echo "Start Session for Phone B"
# Simulate Phone B (HospitalB-admin)
PHONE_B=$(curl -sk \
  --cert ../vfp-governance/verifier/certs/HospitalB-admin.crt \
  --key  ../vfp-governance/verifier/certs/HospitalB-admin.key \
  "${BASE}/verify-start")
echo "Phone_B 6-digits code: $PHONE_B"

