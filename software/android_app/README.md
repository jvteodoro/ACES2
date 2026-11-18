# ACES2 Android Configurator

Aplicativo Android em React Native/Expo para atualizar Wi-Fi e destino UDP do
ESP32 por Bluetooth Low Energy (BLE), sem recompilar ou regravar o firmware a
cada mudança de rede.

## O que o app faz

- Localiza o periférico BLE `ACES2-AUDIO` e conecta ao serviço de configuração.
- Lê o SSID atual do celular quando o usuário concede permissão; também permite
  digitá-lo manualmente.
- Solicita a senha do Wi-Fi, o IP IPv4 do computador, a porta UDP e o MAGIC
  hexadecimal de 32 bits que identifica o dispositivo de captura.
- Autentica a sessão com desafio HMAC-SHA256. Uma senha incorreta faz o ESP32
  encerrar a conexão BLE, que volta a anunciar para permitir outra conexão.
- Cifra a configuração com AES-256-GCM usando uma chave derivada da senha de
  provisionamento. A senha Wi-Fi não trafega em claro pelo BLE.
- O ESP32 grava a configuração em NVS e reinicia para aplicar a rede. Os dados
  persistem quando o ESP32 é desenergizado; BLE volta a anunciar no próximo boot.
- O app salva os campos no armazenamento seguro do Android e os restaura entre
  sessões. Isso inclui as senhas BLE e Wi-Fi, protegidas pelo sistema Android.

O BLE usa uma senha única de pelo menos 16 caracteres. Copie
`../esp32/main/provisioning_config.h.example` para
`../esp32/main/provisioning_config.h`, escolha a senha e grave o firmware uma
vez. O arquivo local `provisioning_config.h` é ignorado pelo Git. O usuário do
app informa a mesma senha para autorizar alterações.

O Android permite consultar o SSID atual sob as permissões de Bluetooth e
localização apropriadas, mas não permite a um app comum extrair a senha Wi-Fi
salva. Por isso, o SSID é sugerido automaticamente e a senha deve ser digitada
no app. Ela é enviada cifrada ao ESP32 e também fica guardada no armazenamento
seguro do Android para preencher o app na próxima sessão.

## Preparar o ESP32

No diretório `software/esp32`:

```bash
cp main/wifi_config.h.example main/wifi_config.h
cp main/provisioning_config.h.example main/provisioning_config.h
```

Edite `main/provisioning_config.h` e substitua a senha de exemplo por uma frase
forte com pelo menos 16 caracteres. `main/wifi_config.h` continua fornecendo
SSID/senha/IP/porta/MAGIC de fallback para a primeira inicialização; depois de
provisionar pelo app, os valores do NVS têm prioridade. Compile e grave o
firmware inicial:

```bash
source /home/enoch/.espressif/tools/activate_idf_v6.1.sh
idf.py build
idf.py -p /dev/ttyUSB0 flash
```

O ESP32 inicia o anúncio BLE `ACES2-AUDIO` automaticamente e mantém esse
serviço ativo enquanto o Wi-Fi e o fluxo de áudio funcionam. O rádio Wi-Fi/BLE
compartilha a antena de 2,4 GHz do ESP32; o fluxo BLE de configuração é curto.

## Preparar e executar o app

É necessário Android Studio/Android SDK, Node.js e JDK. Este app contém módulos
nativos BLE e Wi-Fi, então não roda dentro do Expo Go. Gere um development build
ou APK nativo:

```bash
cd software/android_app
npm install
npx expo prebuild --platform android
npx expo run:android
```

Na tela do app:

1. Localize `ACES2-AUDIO` e conecte.
2. Informe a senha BLE definida em `provisioning_config.h`.
3. Use “SSID do Wi-Fi conectado no celular” ou preencha o SSID. Digite a senha
   Wi-Fi e o IP do computador que executa o receptor UDP; informe a porta
   (normalmente `5000`) e o MAGIC hexadecimal de 32 bits. O padrão `41434553`
   corresponde a `ACES`. São aceitos todos os valores de `00000000` a `FFFFFFFF`;
   use um MAGIC diferente para cada unidade.
4. Toque em “Autenticar e salvar”. O ESP32 valida e grava em NVS e reinicia.
   Inicie o receptor no computador na porta configurada.

Para repetir o procedimento de bring-up, preencha SSID e senha Wi-Fi no app e
execute na raiz do repositório:

```bash
python3 software/android_app/scripts/adb_provision.py \
  --destination-ip auto --port 5000 --magic 41434553
```

O script prepara o Metro/ADB, lê a senha BLE do `provisioning_config.h` local
sem exibi-la, configura IP/porta/MAGIC, conecta e salva. Use `--prepare-only`
para conectar e preencher sem reiniciar o ESP32. É necessário ter um único
celular visível pelo ADB ou passar `--device SERIAL`.

Se o celular e o ESP32 forem associados ao mesmo Wi-Fi, confirme que a rede
permite comunicação entre clientes. Redes de convidados e alguns hotspots
bloqueiam tráfego local.

## Protocolo BLE GATT

UUID do serviço exposto pelo firmware NimBLE atual:
`aca20020-e86d-30b1-7c4a-923e81425c6a`.

| Característica | UUID | Operações |
|---|---|---|
| Desafio | `aca20021-e86d-30b1-7c4a-923e81425c6a` | Read; retorna 16 bytes aleatórios em hexadecimal |
| Comando | `aca20022-e86d-30b1-7c4a-923e81425c6a` | Write with response; recebe frames binários |
| Estado | `aca20023-e86d-30b1-7c4a-923e81425c6a` | Read/notify; `LOCKED`, `AUTH_OK` ou resultado de gravação |

As escritas são frames binários compatíveis com MTU BLE 247 (até 244 bytes por
write). O frame `0x01 || HMAC-SHA256-hex-ASCII` autentica o desafio. O frame de
configuração é `0x02 || IV de 12 bytes || ciphertext AES-GCM || tag de 16 bytes`;
o texto claro cifrado contém `SSID\nsenha-Wi-Fi\nIP\nporta\nMAGIC`. MAGIC é
codificado como hexadecimal com prefixo `0x` e ocupa 32 bits no cabeçalho UDP.
O ESP32 também aceita o formato anterior de quatro campos e usa o MAGIC padrão.
A chave AES é
derivada via HMAC-SHA256 da senha de provisionamento e do desafio não reutilizável.
O ESP32 aceita configuração somente após autenticação válida.

## Limitações

- O app sugere o SSID conectado, mas o Android não fornece a senha Wi-Fi a
  aplicativos comuns.
- O IP do receptor é informado manualmente; o backend deve escutar UDP nessa
  porta e aceitar o MAGIC configurado. O receptor deste repositório aceita
  vários identificadores com opções `--magic` repetidas.
- A chave BLE é definida no firmware. Alterá-la requer uma nova gravação; as
  mudanças de SSID, senha Wi-Fi, IP, porta e MAGIC não.
- O armazenamento NVS não foi configurado com criptografia de flash nesta
  versão. A senha Wi-Fi fica persistida no ESP32 e deve-se proteger fisicamente
  o dispositivo.
