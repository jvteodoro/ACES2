import React, { useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  PermissionsAndroid,
  Platform,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';
import { BleManager } from 'react-native-ble-plx';
import WifiManager from 'react-native-wifi-reborn';
import { hmac } from '@noble/hashes/hmac.js';
import { sha256 } from '@noble/hashes/sha256.js';
import { gcm } from '@noble/ciphers/aes.js';
import { Buffer } from 'buffer';
import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import { StatusBar } from 'expo-status-bar';

// These UUID strings reflect the byte order used by the current NimBLE
// firmware definitions in provisioning_ble.c.
const SERVICE = 'aca20020-e86d-30b1-7c4a-923e81425c6a';
const CHALLENGE = 'aca20021-e86d-30b1-7c4a-923e81425c6a';
const COMMAND = 'aca20022-e86d-30b1-7c4a-923e81425c6a';
const STATUS = 'aca20023-e86d-30b1-7c4a-923e81425c6a';
const DEVICE_NAME = 'ACES2-AUDIO';
const SETTINGS_KEY = 'aces2-provisioning-settings-v1';

const toText = (base64) => Buffer.from(base64, 'base64').toString('utf8');
const toBase64Bytes = (bytes) => Buffer.from(bytes).toString('base64');
const isIpv4 = (value) => {
  const parts = value.split('.');
  return parts.length === 4 && parts.every((part) =>
    /^\d{1,3}$/.test(part) && Number(part) <= 255);
};
const normalizeMagic = (value) => {
  const digits = value.trim().replace(/^0x/i, '');
  if (!/^[0-9a-f]{1,8}$/i.test(digits)) return null;
  return `0x${digits.padStart(8, '0').toUpperCase()}`;
};

async function requestBlePermissions(includeWifiLocation = false) {
  if (Platform.OS !== 'android') return true;
  const permissions = Platform.Version >= 31
    ? [PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
       PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT]
    : [PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION];
  if (includeWifiLocation && !permissions.includes(PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION))
    permissions.push(PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION);
  const result = await PermissionsAndroid.requestMultiple(permissions);
  return permissions.every((permission) =>
    result[permission] === PermissionsAndroid.RESULTS.GRANTED);
}

export default function App() {
  const [manager] = useState(() => new BleManager());
  const deviceRef = useRef(null);
  const statusSubscription = useRef(null);
  const sessionKey = useRef(null);
  const [ssid, setSsid] = useState('');
  const [wifiPassword, setWifiPassword] = useState('');
  const [blePassword, setBlePassword] = useState('');
  const [destinationIp, setDestinationIp] = useState('');
  const [destinationPort, setDestinationPort] = useState('5000');
  const [magic, setMagic] = useState('41434553');
  const [settingsLoaded, setSettingsLoaded] = useState(false);
  const [busy, setBusy] = useState(false);
  const [connected, setConnected] = useState(false);
  const [message, setMessage] = useState('Pronto para localizar o ACES2.');

  useEffect(() => () => {
    statusSubscription.current?.remove();
    manager.stopDeviceScan();
    manager.destroy();
  }, [manager]);

  useEffect(() => {
    let mounted = true;
    SecureStore.getItemAsync(SETTINGS_KEY)
      .then((stored) => {
        if (!mounted || !stored) return;
        const settings = JSON.parse(stored);
        if (typeof settings.ssid === 'string') setSsid(settings.ssid);
        if (typeof settings.wifiPassword === 'string') setWifiPassword(settings.wifiPassword);
        if (typeof settings.blePassword === 'string') setBlePassword(settings.blePassword);
        if (typeof settings.destinationIp === 'string') setDestinationIp(settings.destinationIp);
        if (typeof settings.destinationPort === 'string') setDestinationPort(settings.destinationPort);
        if (typeof settings.magic === 'string') setMagic(settings.magic);
      })
      .catch((error) => console.warn('Não foi possível restaurar as configurações locais:', error))
      .finally(() => {
        if (mounted) setSettingsLoaded(true);
      });
    return () => { mounted = false; };
  }, []);

  useEffect(() => {
    if (!settingsLoaded) return undefined;
    const settings = JSON.stringify({
      ssid, wifiPassword, blePassword, destinationIp, destinationPort, magic,
    });
    const timer = setTimeout(() => {
      SecureStore.setItemAsync(SETTINGS_KEY, settings)
        .catch((error) => console.warn('Não foi possível salvar as configurações locais:', error));
    }, 400);
    return () => clearTimeout(timer);
  }, [settingsLoaded, ssid, wifiPassword, blePassword,
    destinationIp, destinationPort, magic]);

  const getCurrentSsid = async () => {
    try {
      const allowed = await requestBlePermissions(true);
      if (!allowed) throw new Error('Permita acesso à localização para ler o SSID no Android.');
      const current = await WifiManager.getCurrentWifiSSID();
      setSsid(current.replace(/^"|"$/g, ''));
      setMessage(`Rede atual detectada: ${current}`);
    } catch (error) {
      Alert.alert('Não foi possível ler a rede',
        `${error.message || error}\nVocê pode preencher o SSID manualmente.`);
    }
  };

  const findAndConnect = async () => {
    if (!(await requestBlePermissions())) {
      Alert.alert('Permissão necessária', 'Permita Bluetooth para localizar o ESP32.');
      return;
    }
    setBusy(true);
    setMessage('Procurando ACES2-AUDIO…');
    manager.stopDeviceScan();
    manager.startDeviceScan(null, { allowDuplicates: false }, async (error, device) => {
      if (error) {
        manager.stopDeviceScan();
        setBusy(false);
        setMessage(`Falha na busca BLE: ${error.message}`);
        return;
      }
      if (device?.name !== DEVICE_NAME && device?.localName !== DEVICE_NAME) return;
      manager.stopDeviceScan();
      try {
      // Keep the BLE session open while the user enters the network settings.
      // The library's timeout applies to the connection observable and can
      // disconnect an otherwise healthy GATT link after the timeout elapses.
      const connectedDevice = await device.connect();
        await connectedDevice.requestMTU(247);
        await connectedDevice.discoverAllServicesAndCharacteristics();
        deviceRef.current = connectedDevice;
        statusSubscription.current?.remove();
        statusSubscription.current = connectedDevice.monitorCharacteristicForService(
          SERVICE, STATUS, (notifyError, characteristic) => {
            if (notifyError) return;
            if (characteristic?.value) {
              const status = toText(characteristic.value);
              if (status === 'AUTH_FAILED') {
                setMessage('Senha BLE incorreta; o ESP32 encerrou esta conexão.');
              } else if (status === 'SAVED_REBOOTING') {
                setMessage('Configuração salva no ESP32. Ele vai reiniciar e conectar ao Wi-Fi.');
              } else {
                setMessage(`ESP32: ${status}`);
              }
              if (status === 'LOCKED') sessionKey.current = null;
            }
          },
        );
        setConnected(true);
        setBusy(false);
        setMessage('Conectado. Informe a senha de configuração BLE e autentique.');
        connectedDevice.onDisconnected(() => {
          setConnected(false);
          deviceRef.current = null;
          setMessage((current) => {
            if (current.startsWith('Configuração salva no ESP32.') ||
                current.startsWith('Não foi possível salvar:') ||
                current.startsWith('Senha BLE incorreta;') ||
                current.startsWith('Falha na autenticação BLE:')) {
              return current;
            }
            return 'Bluetooth desconectado.';
          });
        });
      } catch (connectError) {
        setBusy(false);
        setMessage(`Não foi possível conectar: ${connectError.message}`);
      }
    });
    setTimeout(() => {
      manager.stopDeviceScan();
      setBusy(false);
      setMessage((current) => current === 'Procurando ACES2-AUDIO…'
        ? 'ESP32 não encontrado. Confirme se está ligado e perto do celular.' : current);
    }, 12000);
  };

  const sendCommand = async (command) => {
    const device = deviceRef.current;
    if (!device) throw new Error('Conecte ao ESP32 primeiro.');
    await device.writeCharacteristicWithResponseForService(
      SERVICE, COMMAND, toBase64Bytes(command));
    await new Promise((resolve) => setTimeout(resolve, 180));
    const status = await device.readCharacteristicForService(SERVICE, STATUS);
    return toText(status.value);
  };

  const authenticate = async () => {
    if (blePassword.length < 16) {
      Alert.alert('Senha curta', 'Use a senha BLE configurada no firmware (mínimo 16 caracteres).');
      return false;
    }
    const device = deviceRef.current;
    if (!device) return false;
    try {
      const challengeValue = await device.readCharacteristicForService(SERVICE, CHALLENGE);
      const nonce = Buffer.from(toText(challengeValue.value), 'hex');
      if (nonce.length !== 16) throw new Error('Desafio BLE inválido.');
      const passwordKey = Buffer.from(blePassword, 'utf8');
      const digest = hmac(sha256, passwordKey, nonce);
      const context = Buffer.concat([nonce, Buffer.from('ACES2-SESSION', 'utf8')]);
      sessionKey.current = hmac(sha256, passwordKey, context);
      const digestHexAscii = Buffer.from(digest).toString('hex');
      const authFrame = Buffer.concat([
        Buffer.from([0x01]), Buffer.from(digestHexAscii, 'ascii'),
      ]);
      const status = await sendCommand(authFrame);
      if (status !== 'AUTH_OK') throw new Error('Senha incorreta; o ESP32 encerrou a conexão.');
      return true;
    } catch (error) {
      setMessage(`Falha na autenticação BLE: ${error.message || 'erro GATT sem detalhes'}`);
      if (/incorrect|incorreta|disconnect/i.test(error.message || '')) {
        setConnected(false);
        deviceRef.current = null;
      }
      return false;
    }
  };

  const saveConfig = async () => {
    if (!deviceRef.current) {
      setMessage('Bluetooth desconectado. Toque em Localizar ESP32 antes de salvar.');
      return;
    }
    if (!ssid.trim()) return Alert.alert('SSID ausente', 'Informe a rede Wi-Fi.');
    if (!isIpv4(destinationIp.trim())) {
      return Alert.alert('IP inválido', 'Use um endereço IPv4, por exemplo 192.168.1.20.');
    }
    const port = Number(destinationPort);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
      return Alert.alert('Porta inválida', 'Informe uma porta entre 1 e 65535.');
    }
    const normalizedMagic = normalizeMagic(magic);
    if (!normalizedMagic) {
      return Alert.alert('MAGIC inválido', 'Use de 1 a 8 dígitos hexadecimais, por exemplo 41434553.');
    }
    if ([ssid, wifiPassword, destinationIp, normalizedMagic].some((value) => /[\r\n]/.test(value))) {
      return Alert.alert('Campo inválido', 'Os campos não podem conter quebras de linha.');
    }
    setBusy(true);
    try {
      await SecureStore.setItemAsync(SETTINGS_KEY, JSON.stringify({
        ssid, wifiPassword, blePassword, destinationIp, destinationPort, magic,
      }));
      if (!(await authenticate())) return;
      const plaintext = Buffer.from(
        `${ssid.trim()}\n${wifiPassword}\n${destinationIp.trim()}\n${port}\n${normalizedMagic}`,
        'utf8',
      );
      const iv = Buffer.from(await Crypto.getRandomBytesAsync(12));
      const sealed = gcm(sessionKey.current, iv).encrypt(plaintext);
      const encryptedConfig = Buffer.concat([Buffer.from([0x02]), iv, Buffer.from(sealed)]);
      if (encryptedConfig.length > 244) {
        throw new Error('Configuração longa demais para o MTU BLE negociado.');
      }
      const status = await sendCommand(encryptedConfig);
      if (status !== 'SAVED_REBOOTING') throw new Error(`ESP32 respondeu: ${status}`);
      setMessage('Configuração salva no ESP32. Ele vai reiniciar e conectar ao Wi-Fi.');
      sessionKey.current = null;
    } catch (error) {
      setMessage(`Não foi possível salvar: ${error.message}`);
    } finally {
      setBusy(false);
    }
  };

  return (
    <SafeAreaView style={styles.safe}>
      <StatusBar style="dark" />
      <ScrollView contentContainerStyle={styles.container} keyboardShouldPersistTaps="handled">
        <Text style={styles.kicker}>ACES2 · CONFIGURAÇÃO</Text>
        <Text style={styles.title}>Conecte o ESP32 ao Wi-Fi</Text>
        <Text style={styles.description}>
          As alterações são salvas na memória do ESP32. Não é necessário gravar o firmware
          ao trocar de rede, servidor, porta ou MAGIC. Os campos também ficam salvos com
          segurança neste celular para a próxima sessão.
        </Text>

        <View style={styles.card}>
          <Text style={styles.section}>1. Bluetooth</Text>
          <TouchableOpacity style={styles.button} onPress={findAndConnect} disabled={busy}>
            {busy ? <ActivityIndicator color="#fff" /> :
              <Text style={styles.buttonText}>{connected ? 'Reconectar ao ESP32' : 'Localizar ESP32'}</Text>}
          </TouchableOpacity>
          <Text style={styles.status}>{message}</Text>
          <TextInput style={styles.input} value={blePassword} onChangeText={setBlePassword}
            placeholder="Senha de configuração BLE" secureTextEntry autoCapitalize="none" />
        </View>

        <View style={styles.card}>
          <Text style={styles.section}>2. Rede Wi-Fi</Text>
          <TouchableOpacity style={styles.secondary} onPress={getCurrentSsid}>
            <Text style={styles.secondaryText}>Usar SSID do Wi-Fi conectado no celular</Text>
          </TouchableOpacity>
          <TextInput style={styles.input} value={ssid} onChangeText={setSsid}
            placeholder="SSID / nome da rede" autoCapitalize="none" />
          <TextInput style={styles.input} value={wifiPassword} onChangeText={setWifiPassword}
            placeholder="Senha do Wi-Fi" secureTextEntry autoCapitalize="none" />
          <Text style={styles.hint}>
            O Android não permite que o app leia a senha Wi-Fi salva. Digite-a aqui; ela será
            enviada ao ESP32 por uma resposta HMAC autenticada e gravada em NVS.
          </Text>
        </View>

        <View style={styles.card}>
          <Text style={styles.section}>3. Destino UDP</Text>
          <TextInput style={styles.input} value={destinationIp} onChangeText={setDestinationIp}
            placeholder="IP do computador, ex. 192.168.1.20" />
          <TextInput style={styles.input} value={destinationPort} onChangeText={setDestinationPort}
            placeholder="Porta UDP (padrão 5000)" keyboardType="number-pad" />
          <TextInput style={styles.input} value={magic} onChangeText={setMagic}
            placeholder="ID/MAGIC hexadecimal, ex. 41434553" autoCapitalize="characters"
            autoCorrect={false} />
          <Text style={styles.hint}>
            Aceita 00000000 a FFFFFFFF. É o identificador de 32 bits incluído em cada pacote;
            use um valor único para cada dispositivo de captura.
          </Text>
        </View>

        <TouchableOpacity style={[styles.button, styles.save]} onPress={saveConfig}
          disabled={busy || !connected}>
          {busy ? <ActivityIndicator color="#fff" /> :
            <Text style={styles.buttonText}>Autenticar e salvar no ESP32</Text>}
        </TouchableOpacity>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, backgroundColor: '#f3f6fb' },
  container: { padding: 20, paddingBottom: 40 },
  kicker: { color: '#087e8b', fontWeight: '800', letterSpacing: 1.5, marginTop: 12 },
  title: { color: '#172b4d', fontSize: 28, fontWeight: '800', marginTop: 8 },
  description: { color: '#52627a', fontSize: 15, lineHeight: 22, marginTop: 10, marginBottom: 18 },
  card: { backgroundColor: '#fff', borderRadius: 16, padding: 16, marginBottom: 14,
    elevation: 2, shadowColor: '#172b4d', shadowOpacity: 0.08, shadowRadius: 8 },
  section: { fontSize: 17, fontWeight: '700', color: '#172b4d', marginBottom: 12 },
  input: { backgroundColor: '#f6f8fb', borderColor: '#dbe3ef', borderWidth: 1,
    borderRadius: 10, paddingHorizontal: 12, paddingVertical: 12, fontSize: 15,
    color: '#172b4d', marginTop: 10 },
  button: { minHeight: 48, backgroundColor: '#087e8b', borderRadius: 11,
    justifyContent: 'center', alignItems: 'center', padding: 12 },
  save: { backgroundColor: '#174ea6', marginTop: 2 },
  buttonText: { color: '#fff', fontSize: 15, fontWeight: '700' },
  secondary: { paddingVertical: 10 },
  secondaryText: { color: '#087e8b', fontWeight: '700' },
  status: { color: '#52627a', fontSize: 13, lineHeight: 18, marginTop: 10 },
  hint: { color: '#65748b', fontSize: 12, lineHeight: 18, marginTop: 10 },
});
