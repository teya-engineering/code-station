# Publicar o Teya Code Station

Distribuição fora da App Store: **Developer ID Application + hardened runtime + notarização + DMG**. Sem isto, quem faz download vê *"não pode ser aberto porque a Apple não conseguiu verificar se contém software malicioso"*.

Team ID: `QZG8V8U2Y6` · Bundle ID: `com.teya.code-station`

## 0. O que já está feito

- [x] Certificado **Developer ID Application — Teya Services Limited**, válido até 2031-09-01
- [x] Certificado descarregado e instalado na Keychain
- [x] Chave de API do App Store Connect no sítio certo (`~/private_keys/AuthKey_2VM7JH4JUA.p8`)
- [x] Primeira release manual (1.0.0, notarizada e validada com quarentena a 2026-08-31)
- [ ] Workflow de CI

## 1. Instalar o certificado

Na página do certificado, clica **Download**, depois duplo-clique no `.cer`. Confirma:

```bash
security find-identity -v -p codesigning
```

Tem de aparecer:

```
1) ABC123… "Developer ID Application: Teya Services Limited (QZG8V8U2Y6)"
```

Se aparecer o certificado mas o `codesign` falhar com *"no identity found"*, é porque a chave privada não está nesta máquina. A chave privada só existe no Mac onde geraste o `.certSigningRequest`. Nesse caso, exporta de lá o par certificado+chave como `.p12`.

## 2. Chave de API do App Store Connect

Guarda o `.p8` fora do repositório (ex.: `~/private_keys/AuthKey_XXXXXXXXXX.p8`). Precisas de três coisas: o ficheiro, o **Key ID** e o **Issuer ID** (App Store Connect → Users and Access → Integrations → Keys).

## 3. Ficheiros a adicionar ao repo

```
Resources/CodeStation.entitlements   # hardened runtime, mínimo
Scripts/release.sh                   # build → assinar → notarizar → DMG
.github/workflows/release.yml        # o mesmo, em CI, por tag
```

## 4. Release manual (faz esta primeiro)

```bash
export AC_API_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
export AC_API_KEY_ID=XXXXXXXXXX
export AC_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

./Scripts/release.sh 1.0.0
```

O script faz, por esta ordem:

1. `./build-app.sh release`
2. escreve a versão no `Info.plist`
3. reassina tudo com Developer ID, `--options runtime --timestamp` (substitui a assinatura ad-hoc do `build-app.sh`)
4. `notarytool submit --wait` da `.app` → `stapler staple`
5. cria o DMG com atalho para `/Applications`, assina, notariza e faz staple
6. valida com `spctl` e escreve o SHA-256

Demora tipicamente 5–15 minutos, quase tudo à espera da Apple.

### O teste que interessa

**Não testes no Mac onde compilaste** — não tem quarentena. Manda o DMG para outra máquina (ou simula):

```bash
xattr -w com.apple.quarantine "0081;00000000;Safari;" TeyaCodeStation-1.0.0.dmg
```

Depois abre normalmente. Tem de abrir sem avisos e sem botão direito → Abrir.

## 5. Automatizar

Secrets a criar em Settings → Secrets and variables → Actions:

| Secret | Como obter |
|---|---|
| `MACOS_CERTIFICATE_P12` | Keychain Access → certificado + chave → Export `.p12` → `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERTIFICATE_PASSWORD` | a password que puseste ao exportar o `.p12` |
| `AC_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `AC_API_KEY_ID` | Key ID (10 caracteres) |
| `AC_API_ISSUER_ID` | Issuer ID (UUID) |

Depois:

```bash
git tag v1.0.0 && git push origin v1.0.0
```

O workflow cria uma **draft release** com o DMG e o `.sha256`. Revês e publicas.

## 6. Actualizar a página

https://teya-engineering.github.io/code-station/ diz hoje para clonar e correr `./build-app.sh`. Depois da primeira release, o caminho principal passa a ser:

- botão de download apontando para `https://github.com/teya-engineering/code-station/releases/latest`
- requisitos: macOS 14+
- build a partir do código passa a ser a secção "para contribuidores"

Nota: o `build-app.sh` injecta `site-defaults.json` no bundle. Decide se a build pública leva defaults ou vai sem configuração — o que for para dentro do `.app` fica assinado e é distribuído a toda a gente.

## Problemas comuns

| Sintoma | Causa |
|---|---|
| `notarytool` devolve `Invalid` | corre `xcrun notarytool log <id> --key … --key-id … --issuer …`; quase sempre é um binário sem hardened runtime ou sem secure timestamp |
| App crasha só depois de assinada | falta um entitlement — vê os comentários em `CodeStation.entitlements` e acrescenta um de cada vez |
| `The signature does not include a secure timestamp` | faltou `--timestamp`, ou a máquina não tinha rede ao assinar |
| `spctl` diz `rejected` mesmo notarizado | esqueceste o `stapler staple`, ou testaste um ficheiro sem quarentena |
| Erro de keychain em CI | falta o `security set-key-partition-list` |
