# PowerAdjuster
Connect IQ Power Adjuster.

# Generate your key
```
$openssl genrsa -out developer_key.pem 4096
$openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt
```

# Build
```
$monkeyc -o PowerAdjuster.prg -m manifest.xml -y developer_key.der -z resources/strings.xml -z resources/bitmaps.xml -z resources/properties.xml source/PowerAdjusterApp.mc source/PowerAdjusterView.mc 
```

# Run in emulator
```
$connectiq
$monkeydo PowerAdjuster.prg edge_1000
```
