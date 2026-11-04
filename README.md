# 🛡️ Proxmox VE - Suite de Copias de Seguridad y Gestión en USB Externo (`backup.sh`)

Una suite completa, interactiva y desatendida en Bash diseñada para realizar copias de seguridad de nodos **Proxmox VE (PVE)** directamente a discos duros externos o unidades USB, sin necesidad de infraestructura externa ni Proxmox Backup Server (PBS).

---

## 📋 Índice

- [Características Principales](#-características-principales)
- [Requisitos Previos](#-requisitos-previos)
- [Instalación y Configuración Inicial](#-instalación-y-configuración-inicial)
- [Panel de Gestión Interactivo (TUI)](#-panel-de-gestión-interactivo-tui)
- [Uso por Línea de Comandos (CLI / Automatización)](#-uso-por-línea-de-comandos-cli--automatización)
- [Conceptos Críticos y Mejores Prácticas](#-conceptos-críticos-y-mejores-prácticas)
  - [Discos Passthrough y la directiva `backup=0`](#discos-passthrough-y-la-directiva-backup0)
  - [Sistemas de Archivos: Peligro de FAT32 frente a ext4/exfat](#sistemas-de-archivos-peligro-de-fat32-frente-a-ext4exfat)
  - [Verificación de Integridad de Copias](#verificación-de-integridad-de-copias)
  - [Bloqueos residuales de Proxmox (`lock: backup`)](#bloqueos-residuales-de-proxmox-lock-backup)
- [Procedimiento de Restauración](#-procedimiento-de-restauración)
  - [Restaurar Máquinas Virtuales (KVM / QEMU)](#restaurar-máquinas-virtuales-kvm--qemu)
  - [Restaurar Contenedores (LXC)](#restaurar-contenedores-lxc)
  - [Restaurar Configuración del Host Proxmox](#restaurar-configuración-del-host-proxmox)
- [Estructura del Almacenamiento en USB](#-estructura-del-almacenamiento-en-usb)
- [Configuración Persistente (`/root/backup.conf`)](#-configuración-persistente)
- [Resolución de Problemas Frecuentes](#-resolución-de-problemas-frecuentes)

---

## 🌟 Características Principales

- **Montaje Resiliente por UUID:** Identifica el disco de copias mediante su identificador único de bloque (`UUID`), evitando errores si el puerto USB o la letra de unidad cambian (`/dev/sdb`, `/dev/sdc`, etc.).
- **Montaje y Desmontaje Seguro y Limpio:** Garantizado mediante trampas del sistema (`trap cleanup_mount EXIT`). El disco nunca queda montado residualmente ni expuesto a desconexiones en caliente que provoquen corrupción.
- **Protección Anticolisión (`flock`):** Evita la ejecución simultánea de múltiples instancias que puedan colapsar los discos o saturar la CPU.
- **Respaldo en Caliente con `vzdump`:** Modo `snapshot` con compresión `zstd` ultrarrápida para Máquinas Virtuales QEMU y Contenedores LXC sin interrumpir los servicios.
- **Respaldo del Host Proxmox:** Empaqueta en `proxmox-host-config-<STAMP>.tar.gz` configuraciones clave del hipervisor: `/etc/pve`, `/etc/network/interfaces`, `/etc/hosts`, `/etc/fstab`, repositorios APT, módulos del kernel y hooks de arranque.
- **Gestión Inteligente de Discos Passthrough y Mountpoints LXC:** Detección de discos físicos directos asignados a VMs (`/dev/disk/by-id/...`) y puntos de montaje secundarios en contenedores LXC (`mp0`, `mp1`...) para permitir excluir discos masivos con la directiva `backup=0`, previniendo que saturen el disco USB.
- **Calculadora Exacta de Espacio:** Calcula el espacio requerido analizando disco por disco, tamaño virtual, passthrough y estado de inclusión.
- **Modo Simulación (`--dry-run` / `-n`):** Permite simular todo el flujo de respaldo, espacio requerido, comandos `vzdump` y política de retención sin escribir ni borrar ningún dato real.
- **Pruebas de Integridad sin Restaurar:**
  - Validación de descompresión Zstandard en streaming (`zstd -t`).
  - Verificación y sincronización automática de sumas criptográficas `SHA-256` (`SHA256SUMS`).
- **Centro de Almacenamiento USB Unificado:** Montaje/desmontaje seguro, cambio de unidad por UUID y asistente de formateo a `ext4` o `exfat` con doble confirmación de seguridad.
- **Ajustes de Rendimiento y Lista Negra (Blacklist):**
  - Limitación o ajuste de hilos CPU de compresión ZSTD (`--zstd`).
  - Control de ancho de banda I/O (`--bwlimit`, por defecto `70000` KiB/s) para no degradar el rendimiento del servidor en producción.
  - Exclusión permanente de VMs/LXCs no deseados en backups desatendidos.
- **Desbloqueo Automático:** Detección y limpieza automática de bloqueos huérfanos (`qm unlock` / `pct unlock`) causados por caídas eléctricas o desconexiones previas.
- **Política de Retención Automática (`KEEP_LAST`):** Conserva las últimas $N$ copias por máquina/host y purga de forma segura las más antiguas manteniendo limpio el archivo `SHA256SUMS`.
- **Notificaciones Ricas:**
  - **Telegram:** Mensajes con formato HTML que incluyen desglose de tamaño, tiempo por máquina y estado de salud.
  - **Proxmox VE (Notificaciones Nativas):** Integración directa con los destinos configurados en el panel de Proxmox (`Centro de datos -> Notificaciones`), como `Gmail-Alertas` (SMTP) o `mail-to-root` (Sendmail), vía `--notification-mode notification-system` y `--notification-target`.
  - **Email Manual (Legacy):** Soporte alternativo de envío directo mediante `--mailto`.
- **Centro de Ayuda Integrado:** Documentación interactiva accesible directamente desde el menú del script (`Opción 12` o `h`).

---

## ⚙️ Requisitos Previos

El script se ejecuta como `root` directamente en el nodo de Proxmox VE. Requiere las herramientas estándar de Debian / Proxmox VE:

```bash
# Generalmente preinstaladas en Proxmox VE:
apt-get update
apt-get install -y util-linux zstd tar curl smartmontools
```

---

## 🚀 Instalación y Configuración Inicial

1. **Ubicación recomendada:** Colocar el archivo en el directorio de scripts de administración (por ejemplo `/opt/proxmox-usb-backup/` o `/root/backup/`):

   ```bash
   chmod 755 /opt/proxmox-usb-backup/backup.sh
   ```

2. **Primera ejecución (Detección automática del USB):**
   Al ejecutar el script sin argumentos, detectará los discos conectados y te guiará para elegir la partición USB que se usará como almacenamiento de respaldo:
   ```bash
   ./backup.sh
   ```
   La selección se guardará de forma persistente en `backup.conf` (junto al script).

---

## 🖥️ Panel de Gestión Interactivo (TUI)

Al ejecutar `./backup.sh` sin argumentos, si el disco USB ya está configurado y montado, salta directamente al panel principal con barra de capacidad visual:

```text
================================================================================
                  PANEL DE GESTIÓN Y BACKUP PROXMOX VE A USB
================================================================================
 💽 Estado USB:      MONTADO en /media/backup (/dev/sde1 [ext4], 890G libres)
 📊 Capacidad USB:   [████░░░░░░░░░░░░░░░░]  20% (180G usados / 931G total)
 🔄 Backup activo:   Inactivo (o: EN EJECUCIÓN [PID: 12345] ⚠️)
 📦 Retención:       Conservar últimas 3 copias por VM/Host
 ⚡ Rendimiento:     ZSTD [Auto] | I/O bwlimit [70000 KB/s] | Blacklist [Ninguna]
 📅 Cron automático: Activado (0 3 * * *)
 🔔 Notificaciones:  Telegram [Activado] | Email PVE [Activado (mail-to-root)]
 📄 Log local:       /opt/proxmox-usb-backup/backup.log
--------------------------------------------------------------------------------
 ── OPERACIONES DE COPIA Y RECUPERACIÓN ────────────────────────────────────────
  1)  💾 Lanzar Copia de Seguridad (Primer plano, Segundo plano o Simulación)
  2)  🛑 Detener Copia en Curso (Parar proceso activo y liberar locks)
  3)  🔄 Restaurar una Copia de Seguridad (VMs, LXC o Host)
  4)  📊 Calculadora de Espacio Requerido (Desglose discos y passthrough)

 ── ALMACENAMIENTO USB Y CONTROL DE DISCOS ─────────────────────────────────────
  5)  🔌 Centro de Almacenamiento USB (Montar, Desmontar, Cambiar o Formatear)
  6)  📦 Explorar, Verificar Integridad y Borrar Copias (zstd -t / sha256)
  7)  ⚙️  Gestionar Discos y Passthrough de VMs / LXC (backup=0 / backup=1)

 ── AUTOMATIZACIÓN, RENDIMIENTO Y DIAGNÓSTICO ──────────────────────────────────
  8)  📅 Programar Backup Automático (Configurar Cron del sistema)
  9)  ⚡ Retención, Rendimiento (ZSTD, bwlimit) y Blacklist
 10)  🔍 Diagnóstico de Salud USB (SMART y Errores de Kernel/Disco)
 11)  🔔 Configurar Notificaciones (Telegram y Email Proxmox)
 12)  📜 Gestor de Logs y Centro de Ayuda (Logs en vivo o Guía [h])

  h)  ❓ Abrir directamente el Centro de Ayuda Técnica
  0)  🚪 Salir (también 'q')
--------------------------------------------------------------------------------
```

### Opciones Detalladas del Menú

| Opción | Descripción |
| :--- | :--- |
| **1) Lanzar Copia** | Asistente en 2 pasos: primero elige qué respaldar (Todo, Máquinas específicas por ID o solo Host) y luego el modo de ejecución (Primer plano interactivo, Segundo plano con `nohup` o Simulación `--dry-run`). |
| **2) Detener Copia** | Detiene de forma segura cualquier proceso de backup en segundo plano activo, cancela procesos hijos (`vzdump`, `zstd`), libera bloqueos residuales (`qm unlock` / `pct unlock`) y sincroniza el disco USB. |
| **3) Restaurar Copia** | Asistente de restauración interactivo con tabla compacta: lista las copias del USB con el nombre de cada VM/LXC y ejecuta `qmrestore` o `pct restore` en el almacenamiento de Proxmox que selecciones. |
| **4) Calculadora de Espacio** | Analiza disco por disco cada VM/LXC. Identifica discos virtuales y passthrough, mostrando qué discos se van a respaldar y el total de GB requeridos frente al espacio libre del USB. |
| **5) Centro de Almacenamiento USB** | Permite montar o desmontar la unidad con `sync`, cambiar de disco USB (escaneo por UUID) o formatear a `ext4` / `exfat` mediante el asistente seguro con confirmación `FORMATEAR`. |
| **6) Explorar / Verificar / Borrar** | Muestra una tabla compacta de las copias en el USB con barra de capacidad, permite borrar copias individuales, aplicar la retención o ejecutar el **Test de Integridad** (`t <Nº>` o `t all`). |
| **7) Gestionar Discos y Passthrough** | Detecta discos de VMs QEMU (incluyendo passthrough `/dev/disk/by-id/...`) y puntos de montaje de contenedores LXC (`mp0`, `mp1`...) permitiendo alternar `backup=0` (omitir) o `backup=1` (incluir). |
| **8) Programar Backup (Cron)** | Asistente para programar la copia automática diaria o semanal en el crontab del sistema con el horario que elijas. |
| **9) Retención y Rendimiento** | Permite cambiar la política de retención automática (`KEEP_LAST`), limitar hilos CPU ZSTD (`--zstd`), limitar ancho de banda I/O (`--bwlimit`) o gestionar la lista negra de exclusiones fijas. |
| **10) Diagnóstico de Salud USB** | Ejecuta diagnósticos SMART sobre el disco USB y revisa el log del kernel (`dmesg`) en busca de errores I/O de disco. |
| **11) Configurar Notificaciones** | Configura credenciales para Telegram (Token de Bot y Chat ID con prueba de envío) y vincula destinos nativos de notificación de Proxmox VE. |
| **12) Gestor de Logs / Ayuda (`h`)** | Visualiza el archivo de log en tiempo real (`tail -f`), muestra los últimos errores, vacía el log o abre el Centro de Ayuda Técnica (también accesible pulsando `h`). |

---

## 💻 Uso por Línea de Comandos (CLI / Automatización)

El script cuenta con un modo de ejecución por comandos que no requiere interacción humana, ideal para tareas programadas con `cron`, scripts de monitoreo o invocación mediante SSH:

```bash
backup.sh [OPCIONES]
```

### Opciones Disponibles

| Bandera | Argumento | Descripción |
| :--- | :--- | :--- |
| `-a`, `--all` | Ninguno | Respalda automáticamente todas las VMs, Contenedores LXC y la configuración del Host. |
| `-y`, `--yes` | Ninguno | Omite cualquier pregunta interactiva (asume respuesta afirmativa 'SÍ'). |
| `-n`, `--dry-run` | Ninguno | Simula todo el proceso de copia, comandos `vzdump` y purga de retención sin escribir ni borrar datos reales. |
| `--vms` | `id1,id2,...` | Especifica una lista separada por comas de IDs a respaldar (ej: `--vms 100,104`). |
| `--with-host` | Ninguno | Incluye el respaldo del host al usar `--vms`. |
| `--no-host` | Ninguno | Excluye el respaldo del host al usar `--vms` o `--all`. |
| `--host-only` | Ninguno | Respalda únicamente la configuración del host Proxmox (omite VMs y LXCs). |
| `--stop`, `--kill` | Ninguno | Detiene limpiamente cualquier proceso de backup en ejecución, libera locks y sincroniza el disco USB. |
| `--keep` | `<N>` | Sobrescribe temporalmente el número de copias a conservar. |
| `--uuid` | `<UUID>` | Sobrescribe el UUID del disco USB a utilizar en esta ejecución. |
| `--zstd` | `<N>` | Define el número de hilos CPU a usar por `zstd` en `vzdump`. |
| `--bwlimit` | `<KB/s>` | Fija el límite de ancho de banda I/O en KiB/s (ej: `70000` = ~70 MiB/s). |
| `--blacklist`| `id1,id2,...`| Sobrescribe la lista negra de máquinas a ignorar. |
| `--bg`, `--background` | Ninguno | Lanza la tarea automáticamente en segundo plano con `nohup`. |
| `--mount` | Ninguno | Monta el disco USB configurado en el punto de montaje y sale con código 0. |
| `--umount` | Ninguno | Desmonta de forma segura el disco USB y sale con código 0. |
| `--cron-status` | Ninguno | Muestra la tarea automática configurada en crontab y su horario legible. |
| `--cron-remove` | Ninguno | Elimina la tarea de backup de crontab. |
| `--telegram-test`| Ninguno | Envía un mensaje de prueba a Telegram y verifica la conexión. |
| `-h`, `--help` | Ninguno | Muestra la ayuda rápida en la terminal. |

### Ejemplos Prácticos de Comandos

1. **Backup completo desatendido (recomendado para cron o tareas nocturnas):**
   ```bash
   /opt/proxmox-usb-backup/backup.sh --all -y
   ```

2. **Lanzar en segundo plano inmune a desconexión SSH (`nohup`):**
   ```bash
   nohup /opt/proxmox-usb-backup/backup.sh --all -y >/dev/null 2>&1 &
   ```
   *(También puedes usar el atajo nativo: `./backup.sh --all -y --bg`)*

3. **Respaldar únicamente las VMs 100 y 104 (incluyendo además la configuración del host):**
   ```bash
   /opt/proxmox-usb-backup/backup.sh --vms 100,104 --with-host -y
   ```

4. **Respaldar con límite de I/O de 40 MB/s (40000 KB/s) y 2 hilos CPU:**
   ```bash
   /opt/proxmox-usb-backup/backup.sh --all -y --bwlimit 40000 --zstd 2
   ```

5. **Montar manualmente el disco USB para copiar un archivo:**
   ```bash
   /opt/proxmox-usb-backup/backup.sh --mount
   ```

6. **Desmontar de forma segura antes de desconectar el cable USB:**
   ```bash
   /opt/proxmox-usb-backup/backup.sh --umount
   ```

---

## 🧠 Conceptos Críticos y Mejores Prácticas

### Discos Passthrough y la directiva `backup=0`

En Proxmox VE es habitual asignar discos duros enteros por hardware a máquinas virtuales de almacenamiento (como TrueNAS, OpenMediaVault o Debian con ZFS/RAID), usando identificadores físicos:
```text
scsi1: /dev/disk/by-id/ata-WDC_WD20EFRX-68EUZN0_WD-WCC4M3JTTPDE
```

#### ¿Por qué fallaba el backup anteriormente?
Por defecto, la herramienta `vzdump` de Proxmox intenta incluir **absolutamente todos** los discos conectados a la máquina virtual. Si una VM tiene un disco virtual de sistema de 300 GB y además tiene 3 discos passthrough de 2 TB, 2 TB y 14 TB (18 TB en total), `vzdump` intentará respaldar los 18 TB. Si tu disco USB tiene 1 TB de capacidad, el proceso fallará inevitablemente con el error:
```text
zstd: error 70 : Write error : cannot write block : No space left on device
```

#### ¿Cómo lo soluciona este script?
Para omitir un disco passthrough en el backup de Proxmox, se debe agregar el parámetro `,backup=0` en su configuración (`/etc/pve/qemu-server/<vmid>.conf`):
```text
scsi1: /dev/disk/by-id/ata-WDC_WD20EFRX...,backup=0
```
- La **Opción 3 (Calculadora)** detecta estos discos y te avisa exactamente cuántos GB representan.
- La **Opción 8 del Menú** te permite marcar o desmarcar `backup=0` con un clic.
- Durante cualquier backup, si el script detecta un disco passthrough sin `backup=0`, emitirá una alerta y te ofrecerá excluirlo de forma automática.

---

### Sistemas de Archivos: Peligro de FAT32 frente a ext4/exfat

#### ¿Por qué FAT32 (`vfat`) es inviable para copias de seguridad de Proxmox?
El sistema de archivos FAT32 tiene una restricción física histórica: **el tamaño máximo de un único archivo es de 4 GiB (4.294.967.295 bytes)**.
Un backup de Proxmox (`.vma.zst`) de una VM con un disco de 50 GB o 300 GB superará con creces los 4 GiB. Tan pronto como el archivo alcance los 4 GiB en una partición FAT32, el kernel de Linux abortará la escritura con error de I/O.

#### Sistemas recomendados:
- **`ext4` (Recomendado):** Sistema de archivos nativo de Linux. Ofrece máximo rendimiento, soporte completo de permisos POSIX, journaling y sin límite práctico de tamaño de archivo.
- **`exfat`:** Recomendado únicamente si necesitas conectar con frecuencia el disco USB directamente a sistemas Windows o macOS sin software adicional.

El script incluye un detector automático y el asistente de formateo en la **Opción 7**.

---

### Verificación de Integridad de Copias

Un respaldo que no se ha verificado no garantiza recuperación ante desastres. El script implementa dos capas de verificación sin restaurar:

1. **Test de Descompresión Zstandard (`zstd -t`):**
   Prueba el flujo de compresión completo del archivo `.vma.zst` o `.tar.zst`, verificando la cabecera, los bloques de datos y los checksums internos de cada bloque.
2. **Sumas de Verificación Criptográficas SHA-256 (`SHA256SUMS`):**
   En cada sesión de copia, se calcula el hash SHA-256 de cada archivo generado. La herramienta de verificación recalcula el hash y comprueba bit a bit que el archivo no haya sufrido "bit rot" o degradación física en los sectores del disco USB.

---

### Bloqueos residuales de Proxmox (`lock: backup`)

Si un backup se cancela de forma abrupta (por ejemplo, desconexión accidental del USB o apagón eléctrico), Proxmox deja una bandera en la configuración del invitado: `lock: backup`. Mientras este bloqueo exista, la máquina no puede encenderse, apagarse ni volver a respaldarse.

El script detecta automáticamente este estado al iniciar y ejecuta de forma transparente:
```bash
qm unlock <vmid>   # Para máquinas virtuales QEMU
pct unlock <vmid>  # Para contenedores LXC
```

---

## 🔄 Procedimiento de Restauración

### Restaurar Máquinas Virtuales (KVM / QEMU)

1. **Desde el menú interactivo:** Selecciona la **Opción 2**, elige la sesión, la VM que deseas restaurar y el almacenamiento destino (ej: `local-lvm`).
2. **Desde la terminal con `qmrestore`:**
   ```bash
   # 1. Montar el disco USB
   ./backup.sh --mount

   # 2. Restaurar asignando un nuevo ID (o sobreescribiendo uno existente con --force 1)
   qmrestore /media/backup/proxmox-backups/2026-10-24_01-00-00/vzdump-qemu-104-2026_10_24-01_09_24.vma.zst 104 --storage local-lvm

   # 3. Desmontar al terminar
   ./backup.sh --umount
   ```

### Restaurar Contenedores (LXC)

1. **Desde el menú interactivo:** Opción 2 del script.
2. **Desde la terminal con `pct restore`:**
   ```bash
   ./backup.sh --mount
   pct restore 105 /media/backup/proxmox-backups/2026-10-24_01-00-00/vzdump-lxc-105-2026_10_24-01_15_00.tar.zst --storage local-lvm
   ./backup.sh --umount
   ```

### Restaurar Configuración del Host Proxmox

El archivo `proxmox-host-config.tar.gz` contiene los archivos de configuración del hipervisor. Para explorar su contenido:
```bash
tar -ztvf /media/backup/proxmox-backups/<FECHA>/proxmox-host-config.tar.gz
```

Para restaurar archivos específicos (por ejemplo, la configuración de interfaces de red):
```bash
tar -xzvf /media/backup/proxmox-backups/<FECHA>/proxmox-host-config.tar.gz -C / etc/network/interfaces
```

---

## 📂 Estructura del Almacenamiento en USB (Compatible con GUI de Proxmox)

Las copias se almacenan en la carpeta estándar que la interfaz web de Proxmox VE lee automáticamente (`/media/backup/dump/`):

```text
/media/backup/                                         <- Raíz física del USB montado
├── dump/                                                <- Directorio nativo estándar de Proxmox VE
│   ├── vzdump-qemu-100-2026_10_24-01_02_00.vma.zst     <- Respaldo VM 100 (visible en Proxmox GUI)
│   ├── vzdump-qemu-100-2026_10_24-01_02_00.log         <- Log de vzdump de la VM 100
│   ├── vzdump-qemu-104-2026_10_24-01_09_24.vma.zst     <- Respaldo VM 104 (visible en Proxmox GUI)
│   ├── vzdump-lxc-102-2026_10_24-01_15_00.tar.zst      <- Respaldo Contenedor LXC 102
│   ├── proxmox-host-config-2026-10-24_01-00-00.tar.gz   <- Configuración del host Proxmox
│   ├── backup-2026-10-24_01-00-00.log                   <- Log general de la sesión
│   └── SHA256SUMS                                       <- Hashes criptográficos de verificación
```

> [!TIP]
> Al estar ubicadas en `dump/`, cualquier copia de VM o LXC aparecerá inmediatamente en la interfaz web de Proxmox bajo el almacenamiento **`backup -> Respaldos`**, permitiendo restaurar directamente con el botón **"Restaurar"** de Proxmox o desde el script.

---

## 📝 Configuración Persistente

Todas las preferencias se almacenan en el mismo directorio del script (`backup.conf`, puedes tomar como plantilla `backup.conf.example`):

```ini
# Configuración persistente del script de backup USB Proxmox VE
USB_UUID="XXXX-XXXX"
MOUNTPOINT="/media/backup"
KEEP_LAST=3
MIN_FREE_GB=20
ZSTD_THREADS=0
BWLIMIT=70000
BLACKLIST_VMS=""
TELEGRAM_ENABLED=1
TELEGRAM_BOT_TOKEN="123456789:ABCdefGhIJKlmNoPQRsTUVwxyZ"
TELEGRAM_CHAT_ID="987654321"
EMAIL_ENABLED=1
EMAIL_NOTIFICATION_TYPE="failure"
NOTIFICATION_TARGET="mail-to-root"
```

---

## 🛠️ Resolución de Problemas Frecuentes

### 1. `ERROR: Ya existe otra instancia de este script ejecutándose`
- **Causa:** Quedó un proceso anterior bloqueando el archivo `backup.lock` en el directorio del script o se lanzó una tarea duplicada.
- **Solución:** Revisa con `ps aux | grep backup.sh` o `ps aux | grep vzdump`. Si ningún proceso está en ejecución, libera el bloqueo con `rm -f /root/backup.lock` (o la ruta donde esté el script).

### 2. `El punto /media/backup ya está montado actualmente`
- **Causa:** El disco quedó montado de una sesión manual previa.
- **Solución:** Ejecuta `./backup.sh --umount` o utiliza la **Opción 4** del menú interactivo para desmontarlo con seguridad.

### 3. `zstd: error 70 : Write error : No space left on device`
- **Causa 1:** El USB está formateado en FAT32 (límite de 4 GiB). Usa la **Opción 7** para formatear a `ext4`.
- **Causa 2:** La VM contiene discos físicos directos (passthrough) de gran capacidad. Usa la **Opción 8** para marcar `backup=0` en dichos discos.

### 4. `La máquina virtual está bloqueada (lock: backup)`
- **Causa:** Un respaldo anterior fue cancelado a la fuerza.
- **Solución:** El script lo desbloquea automáticamente al iniciar el backup. También puedes ejecutar manualmente: `qm unlock <vmid>`.

---

## 📄 Licencia

Este proyecto se distribuye bajo licencia libre para administración de sistemas y entornos de producción con Proxmox VE.
