# MU mubolarg - Cliente

Cliente de MuEMU Season 6 Episode 3 para el server mubolarg.

## Como instalar (PC nueva)

1. **Bajá el ZIP** del repo: click verde "Code" → "Download ZIP"
2. **Descomprimí** donde quieras (ej. `C:\MUClient`)
3. **Doble click en `Apply-ClientFix.exe`** (la primera vez):
   - Setea resolucion windowed 800x600 (la M se ve bien)
   - Aplica compat layer Win7 + RunAsAdmin a main.exe
   - Oculta los archivos internos del cliente (Custom*, dlls, main.emu, etc.) para que la carpeta se vea limpia
4. **Doble click en `MuLauncher.exe`** para entrar al juego

## Requisitos

- **ZeroTier**: el server corre en una red ZeroTier interna. Bajalo de https://www.zerotier.com/download/ e unite a la red del server.
- **Windows 10/11**: el cliente fue testeado en Win11. UAC pide permisos al primer launch (decir Si).
- **Antivirus**: si Windows Defender bloquea el .exe, agregar la carpeta del cliente a exclusiones.

## Auto-update

El launcher se conecta a GitHub al abrir, baja los archivos cambiados, y despues lanza el juego. No hay que hacer nada manual.

Si la conexion a GitHub falla, el launcher avisa pero igual deja jugar (update no obligatorio).

## Estructura de carpetas

Despues de correr `Apply-ClientFix.exe` solo deberian ser visibles:

```
Apply-ClientFix.exe   Fix one-shot (compat layer + ocultar internos)
MuLauncher.exe        Launcher principal (entrypoint)
main.exe              Cliente del juego
Data/                 Datos del juego (mapas, items, NPCs, etc.)
ScreenShots/          Screenshots que sacas con la tecla Print Screen
```

Los archivos internos (Customs, dlls, MainInfo.ini, main.emu, Main.dll) quedan en root pero ocultos.

## Problemas frecuentes

**"No se conecta al server"** → verificá que ZeroTier este corriendo y que estes en la red del server.

**"La tecla M no se ve bien"** → asegurate de tener resolucion 800x600 modo ventana. Eso es lo que setea `Apply-ClientFix`.

**"main.exe no abre / da error"** → la primera vez correr como administrador (click derecho → Ejecutar como administrador). Despues queda asociado.

## Soporte

Pregunta al admin (Liyar) por la red ZeroTier y cualquier otra cosa.
