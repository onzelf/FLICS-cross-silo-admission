
# before using containerized system, members must be enrolled and registered by their organizations

# generate locally on disk
# -------------------------------------------------------
echo "------------------------->"
echo "(1) register member Audrey"
python3 gen_member_keys.py  --org org://HospitalA --who Audrey

DATA=$(jq 'del(.created_at)' holder_keys/Audrey.register.json)
echo $DATA

curl -vk \
  --resolve issuer-hospitala.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalA-admin.key \
  -H "Content-Type: application/json" \
  --data "$DATA" https://issuer-hospitala.local:9443/members/register

# ---------------------------------
echo ""
echo "-------------------> "
echo "register member Bob"
python3 gen_member_keys.py  --org org://HospitalB --who Bob

DATA=$(jq 'del(.created_at)' holder_keys/Bob.register.json)
echo $DATA

curl -vk \
  --resolve issuer-hospitalb.local:9443:192.168.1.25 \
  --cacert ../vfp-governance/verifier/certs/ca.crt \
  --cert  ../vfp-governance/verifier/certs/HospitalB-admin.crt \
  --key   ../vfp-governance/verifier/certs/HospitalB-admin.key \
  -H "Content-Type: application/json" \
  --data "$DATA" https://issuer-hospitalb.local:9443/members/register


# -----------------------------------------
# check register in HospistA
curl -sk --resolve issuer-hospitala.local:9443:192.168.1.25   \
         --cacert ../vfp-governance/verifier/certs/ca.crt   \
         --cert  ../vfp-governance/verifier/certs/HospitalA-admin.crt   \
         --key   ../vfp-governance/verifier/certs/HospitalA-admin.key  \
          https://issuer-hospitala.local:9443/members | jq .

curl -sk --resolve issuer-hospitalb.local:9443:192.168.1.25   \
         --cacert ../vfp-governance/verifier/certs/ca.crt   \
         --cert  ../vfp-governance/verifier/certs/HospitalB-admin.crt   \
         --key   ../vfp-governance/verifier/certs/HospitalB-admin.key  \
          https://issuer-hospitalb.local:9443/members | jq .

echo "done"
echo " "
# -----------------------------------------
# save private key on a simulated secure vault
mkdir -p ../vfp-governance/verifier/vault/holder_keys
cp -v holder_keys/*.privhex     ../vfp-governance/verifier/vault/holder_keys/

