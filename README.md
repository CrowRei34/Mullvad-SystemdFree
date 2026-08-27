# Mullvad VPN en Void Linux

Instalador y servicio runit para Mullvad VPN en Void Linux (que no usa systemd
y no tiene paquete nativo en los repos oficiales).

## Qué hace `install.sh`

1. **Descarga** el `.deb` amd64 oficial de Mullvad desde GitHub Releases.
2. **Verifica la firma GPG** contra la clave de *Mullvad (code signing)*
   (la importa automáticamente desde un keyserver si hace falta).
3. **Extrae** el `.deb` (formato ar/tar) e instala el payload a mano:
   - `/opt/Mullvad VPN/` (GUI Electron + recursos).
   - `/usr/bin/mullvad`, `mullvad-daemon` y `mullvad-exclude` (este último
     con bit setuid).
   - Iconos, entrada `.desktop` y completions de bash/fish.
4. **Crea el servicio runit** `/etc/sv/mullvad-daemon` (con logger `svlogd`
   en `/var/log/mullvad-daemon`) y lo habilita en `/var/service` para que
   arranque solo en cada reinicio.
5. Carga el módulo WireGuard del kernel.

En cada instalación o actualización, el script consulta la última versión
publicada en GitHub, descarga el `.deb` correspondiente y vuelve a verificar
su firma GPG antes de instalarlo.

No instala el servicio de *early-boot blocking* ni el perfil AppArmor del
postinst original: no son necesarios para que la VPN funcione en Void.

## Uso

```sh
# Instalar la última versión
doas sh ~/Documents/mullvad-vpn/install.sh install

# Instalar una versión concreta
doas sh ~/Documents/mullvad-vpn/install.sh install 2026.3

# Actualizar a la última versión
doas sh ~/Documents/mullvad-vpn/install.sh update

# Actualizar a una versión concreta
doas sh ~/Documents/mullvad-vpn/install.sh update 2026.3

# Estado (no requiere root)
sh ~/Documents/mullvad-vpn/install.sh status

# Desinstalar (conserva cuenta, ajustes y logs en /etc/mullvad-vpn y /var/log)
doas sh ~/Documents/mullvad-vpn/install.sh uninstall
```

## Después de instalar

```sh
mullvad account login <tu_numero_de_cuenta>
mullvad connect
mullvad status
```

GUI: búscala como **Mullvad VPN** en el menú de aplicaciones, o ejecuta
`/opt/Mullvad VPN/mullvad-vpn`. Si la GUI no arranca por el sandbox de
Electron, lánzala con `--no-sandbox`.

## Logs del daemon

```sh
cat /var/log/mullvad-daemon/current    # log en vivo
sv status mullvad-daemon               # estado del servicio (como root)
sv down mullvad-daemon                 # parar
sv up mullvad-daemon                   # arrancar
```

## Actualizaciones

El comando `update` no cambia la cuenta, ajustes ni logs de Mullvad. Detiene el
daemon, verifica la nueva versión firmada, reemplaza los binarios y vuelve a
levantar el servicio runit. Si no se indica versión, siempre usa la release más
reciente publicada por Mullvad.

Para automatizarlo con cron o un timer de runit, ejecuta periódicamente:

```sh
doas sh /ruta/al/repositorio/install.sh update
```

## Dependencias del host

`curl`, `gpg`, `ar`, `tar`, `modprobe`, `install`, y runit (`sv`, `svlogd`).
Todas presentes en una instalación base de Void.

## Verificación de la firma

La clave usada para firmar los releases de Mullvad:

- Fingerprint subkey: `CA83 A461 53BC 58D6 9518 ED49 A265 81F2 19C8 314C`
- Fingerprint primary: `A119 8702 FC3E 0A09 A9AE 5B75 D5A1 D4F2 66DE 8DDF`
- UID: `Mullvad (code signing) <admin@mullvad.net>`

El script rechaza la instalación si la firma no es *Good signature*.
