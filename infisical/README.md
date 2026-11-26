

creating an org wide machine idenity

setting infisical machine id secret in k8s

```
read "CID?Client ID: "
read -s "CSEC?Client secret: "; echo
kubectl -n infisical-operator-system create secret generic infisical-k8s-cluster-identity \
  --from-literal=clientId="$CID" --from-literal=clientSecret="$CSEC"
unset CID CSEC:
```