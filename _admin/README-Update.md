# Auto-Update del cliente MU

## Para los jugadores (PCs distintas a la tuya)

1. Copiar la carpeta del cliente entera a la PC
2. Doble click en `Launch MU Launcher.cmd`
3. En el launcher, llenar el campo **Update URL** con la URL del `manifest.json` que te paso el admin
4. Click **Guardar** (queda persistido en `MuLauncher.config.json`)
5. Click **Verificar update** (o cerrar y reabrir el launcher; se ejecuta auto)
6. Cuando dice "Cliente al dia" o "Actualizado N archivos", click **Jugar**

Si el server de updates esta caido o sin conexion, el boton **Jugar** queda deshabilitado (update obligatorio). Avisar al admin.

## Para vos (admin) — workflow de publicar update

### Setup inicial (una vez)

Elegir donde hostear los archivos. Las 3 opciones mas practicas:

**Opcion A — GitHub publico (Recomendado, gratis, HTTPS, sin firewall)**

1. Crear repo publico en GitHub (ej. `liyar/mu-client`)
2. Subir TODA la carpeta del cliente al repo (incluyendo `manifest.json`)
3. La URL del manifest seria: `https://raw.githubusercontent.com/<user>/<repo>/main/manifest.json`
4. Esa es la URL que ponen los jugadores en su launcher

**Opcion B — Google Drive con link directo**

1. Subir la carpeta del cliente comprimida + el `manifest.json` por separado a Drive
2. Para el manifest: click derecho > Compartir > Cualquiera con el link > Copiar link
3. Convertir el link de Drive a "raw" usando un servicio tipo `drive.google.com/uc?export=download&id=<ID>`
4. Mismo proceso para cada archivo. Mas chicaneo que GitHub, mejor evitarlo

**Opcion C — HTTP server propio en tu maquina del MU**

1. Levantar IIS o `python -m http.server 8080` en la carpeta del cliente
2. Abrir puerto en firewall
3. URL: `http://<tu-ip-publica-o-zerotier>:8080/manifest.json`
4. Mejor si los jugadores entran via ZeroTier (mismo subred que el server MU)

### Cada vez que haces un cambio

1. Editas archivos del cliente en tu carpeta local
2. Corres `Build-Manifest.ps1` (doble click en `.cmd` o desde PowerShell)
3. Subis al hosting **al menos** los archivos que cambiaron + `manifest.json`
   - En GitHub: `git add -A; git commit -m "update"; git push`
   - En Drive: subir los archivos cambiados manualmente
4. Listo. Los jugadores reciben el update en su proximo launch

### Verificacion

Antes de avisar a los jugadores que hay update, podes simular en tu propia PC:

1. Borrar (o renombrar) un archivo del cliente local
2. Abrir el launcher
3. Deberia detectar el archivo faltante y bajarlo del hosting

## Formato del manifest.json

```json
{
  "version": "2026-05-25T15:30:00.0000000-03:00",
  "base_url": "",
  "files": [
    { "path": "main.exe", "sha256": "abc...", "size": 3716608 },
    { "path": "Data/Local/Movereq.bmd", "sha256": "def...", "size": 2884 }
  ]
}
```

- `version`: timestamp, info-only (no se usa para logica)
- `base_url`: si vacio, los archivos se buscan en URLs relativas al manifest URL
  (ej. `manifest_url=.../manifest.json` -> `main.exe` se baja de `.../main.exe`)
- `files[].path`: relativo al root del cliente, separador `/`
- `files[].sha256`: hash SHA256 minusculas hex
- `files[].size`: bytes (info-only para mostrar progreso)

## Que excluye Build-Manifest.ps1 por defecto

- `ScreenShots/` (cada player tiene los suyos)
- `*.log`, `*.dmp`, `*.dl-tmp` (logs y temporales)
- `MuLauncher.config.json` (config personal del player)
- `manifest.json` (el propio)
- Logs del GetMainInfo

Estos archivos quedan localmente intactos en cada player; el update no los borra ni los modifica.

## Que NO hace el launcher

- **No remueve archivos locales que no estan en el manifest.** Si un player tiene archivos viejos que vos sacaste, le quedan ahi. Si queres limpiar, distribuye un .cmd dedicado.
- **No se auto-updatea a si mismo en vivo.** Si tenes que cambiar `MuLauncher.ps1`, va a quedar la version vieja corriendo en el current launch; al siguiente abrir, ya carga la nueva.
- **No detecta archivos lockeados** mientras el cliente esta corriendo. Si un player tiene el juego abierto y trata de updatear, falla en Move-Item de los archivos en uso.

## Troubleshooting

**"X No se pudo bajar el manifest"** -> URL mal escrita o hosting caido. Pegar la URL en el navegador y ver si abre el JSON.

**"X Hash mismatch en X tras descargar"** -> archivo en hosting corrupto o tema de cache CDN. Re-subir el archivo.

**"X No pude reemplazar X (archivo en uso?)"** -> tener el cliente abierto al mismo tiempo. Cerrar y reabrir launcher.

**Jugar queda deshabilitado** -> update obligatorio fallo. Solucionar el motivo (red/hosting), click "Verificar update" de nuevo.
