#!/bin/bash

# =============================================================================
# Gentoo Linux Installation Script
# =============================================================================
# Sistema operativo : Gentoo Linux (OpenRC)
# Architettura      : amd64
# Boot mode         : UEFI
# Init system       : OpenRC
# Lingua            : Italiano (it_IT.UTF-8)
# Fuso orario       : Europe/Rome
# Partizionamento   : Personalizzabile dall'utente (EFI + Swap + Root)
# Disco             : Scelto dall'utente (es. /dev/nvme0n1, /dev/sda)
# Conferma distruzione disco: singola lettera "S" (maiuscola)
#
# ATTENZIONE: Questo script cancella COMPLETAMENTE tutti i dati sul disco selezionato.
#             Non è possibile alcun recupero dopo l'avvio del partizionamento.
#
# Testato sulla Gentoo Minimal Installation CD (live environment)
# =============================================================================

set -e

messaggio() {
    echo -e "\n=== $1 ==="
}

# ────────────────────────────── SELEZIONE DISCO ──────────────────────────────
messaggio "Selezione del disco di installazione"
read -p "Inserisci il dispositivo disco (es. /dev/nvme0n1, /dev/sda): " DISK

if [ ! -b "$DISK" ]; then
    echo "ERRORE: $DISK non esiste o non è un dispositivo a blocchi valido."
    exit 1
fi

echo -e "\n!!! ATTENZIONE !!!"
echo "   Tutti i dati presenti su $DISK saranno cancellati in modo irreversibile."
read -p "   Digita la lettera S (maiuscola) per confermare e proseguire: " CONFERMA
if [ "$CONFERMA" != "S" ]; then
    echo "Operazione annullata dall'utente."
    exit 0
fi

# Prefisso partizioni
if [[ $DISK == *nvme* ]] || [[ $DISK == *mmcblk* ]] || [[ $DISK == *nbd* ]]; then
    PART_PREFIX="${DISK}p"
else
    PART_PREFIX="$DISK"
fi

# ────────────────────────────── DIMENSIONI PARTIZIONI ──────────────────────────────
messaggio "Configurazione dimensioni partizioni"
read -p "Dimensione partizione EFI (es. 512M, 1G) [default: 1G]: " EFI_SIZE
EFI_SIZE=${EFI_SIZE:-1G}

read -p "Dimensione partizione swap (es. 8G, 16G) [default: 8G]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-8G}

# Converte dimensioni in MiB
to_mib() {
    local val="$1"
    val="${val^^}"  # uppercase
    if [[ $val == *G ]]; then
        echo $((${val%G} * 1024))
    elif [[ $val == *M ]]; then
        echo ${val%M}
    else
        echo "$val"
    fi
}

EFI_MIB=$(to_mib "$EFI_SIZE")
SWAP_MIB=$(to_mib "$SWAP_SIZE")

# ────────────────────────────── CREDENZIALI UTENTE ──────────────────────────────
messaggio "Impostazione credenziali"
read -p "Password per l'utente root: " -s ROOT_PASSWORD; echo
read -p "Nome utente da creare: " USER_NAME
read -p "Password per l'utente $USER_NAME: " -s USER_PASSWORD; echo

# ────────────────────────────── AMBIENTE LIVE ──────────────────────────────
messaggio "Configurazione ambiente live"
loadkeys it
export LANG=it_IT.UTF-8

# ────────────────────────────── CONNESSIONE DI RETE ──────────────────────────────
messaggio "Configurazione rete"
echo "Avvio client DHCP..."
dhcpcd -q -w

messaggio "Verifica connessione internet"
for i in {1..10}; do
    if ping -c 1 -W 3 8.8.8.8 &>/dev/null || ping -c 1 -W 3 1.1.1.1 &>/dev/null; then
        echo "Connessione internet stabilita."
        break
    else
        echo "Tentativo $i/10 fallito, nuovo tentativo tra 3 secondi..."
        sleep 3
    fi
done

if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
    echo "Connessione non rilevata automaticamente."
    echo "Configura manualmente se necessario (es. iwctl, nmtui, dhcpcd enp0s3...)"
    read -p "Premi INVIO quando hai internet funzionante..."
fi

# ────────────────────────────── PARTIZIONAMENTO CON PARTED ──────────────────────────────
messaggio "Partizionamento del disco $DISK con parted"

parted -s "$DISK" mklabel gpt

# Partizione EFI: da 1MiB a EFI_MIB
parted -s "$DISK" mkpart primary fat32 1MiB "${EFI_MIB}MiB"
parted -s "$DISK" set 1 esp on

# End EFI = EFI_MIB (start è 1, size è EFI_MIB-1, end è EFI_MIB)
END_EFI=$EFI_MIB

# Partizione swap: da END_EFI a END_EFI + SWAP_MIB
SWAP_END=$((END_EFI + SWAP_MIB))
parted -s "$DISK" mkpart primary linux-swap "${END_EFI}MiB" "${SWAP_END}MiB"

# Partizione root: da SWAP_END a 100%
parted -s "$DISK" mkpart primary ext4 "${SWAP_END}MiB" 100%

# Attesa e rilettura partizioni
sleep 3
partprobe "$DISK" 2>/dev/null || true
blockdev --rereadpt "$DISK" 2>/dev/null || true
sleep 2

# Verifica esistenza partizioni
if [ ! -b "${PART_PREFIX}1" ] || [ ! -b "${PART_PREFIX}2" ] || [ ! -b "${PART_PREFIX}3" ]; then
    echo "ERRORE: Una o più partizioni non sono state create correttamente."
    ls -l /dev/${PART_PREFIX}* 2>/dev/null || echo "Nessuna partizione trovata"
    exit 1
fi

echo "Partizionamento completato con successo:"
echo "   EFI  → ${PART_PREFIX}1  (${EFI_SIZE})"
echo "   Swap → ${PART_PREFIX}2  (${SWAP_SIZE})"
echo "   Root → ${PART_PREFIX}3  (resto del disco)"

# ────────────────────────────── FORMATTAZIONE E MONTAGGIO ──────────────────────────────
messaggio "Formattazione delle partizioni"
mkfs.vfat -F 32 "${PART_PREFIX}1"
mkswap "${PART_PREFIX}2"
mkfs.ext4 -F "${PART_PREFIX}3"

messaggio "Attivazione swap"
swapon "${PART_PREFIX}2"

messaggio "Montaggio filesystem"
mkdir -p /mnt/gentoo
mount "${PART_PREFIX}3" /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount "${PART_PREFIX}1" /mnt/gentoo/efi

# ────────────────────────────── SINCRONIZZAZIONE ORA ──────────────────────────────
if command -v chronyd &>/dev/null; then
    chronyd -q
elif command -v ntpd &>/dev/null; then
    ntpd -q -g
elif command -v ntpdate &>/dev/null; then
    ntpdate -s time.google.com
else
    echo "Nessun servizio NTP trovato. Imposta l'ora manualmente se necessario."
fi

# ────────────────────────────── DOWNLOAD STAGE3 ──────────────────────────────
messaggio "Download e verifica stage3 OpenRC"
cd /mnt/gentoo
wget -q https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt
STAGE_FILE=$(grep -v '^#' latest-stage3-amd64-openrc.txt | head -1 | awk '{print $1}')
STAGE_BASENAME=$(basename "$STAGE_FILE")

wget -c https://distfiles.gentoo.org/releases/amd64/autobuilds/"$STAGE_FILE"
wget -c https://distfiles.gentoo.org/releases/amd64/autobuilds/"$STAGE_FILE".DIGESTS.asc

# Verifica SHA512
grep -A1 SHA512 "$STAGE_FILE".DIGESTS.asc | grep -v '^--' | \
    awk -v fname="$STAGE_BASENAME" '{print $1 "  " fname}' | \
    sha512sum -c --quiet && echo "Verifica integrità stage3: OK" || echo "ATTENZIONE: verifica SHA512 fallita!"

messaggio "Estrazione stage3"
tar xpf "$STAGE_BASENAME" --xattrs-include='*.*' --numeric-owner

# ────────────────────────────── PREPARAZIONE CHROOT ──────────────────────────────
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# ────────────────────────────── CONFIGURAZIONE FINALE NEL CHROOT ──────────────────────────────
messaggio "Configurazione del sistema nel chroot"
chroot /mnt/gentoo /bin/bash <<CHROOT_EOF
source /etc/profile
export PS1="(chroot) \$PS1"

# Crea directory per portage
mkdir -p /etc/portage

# fstab con UUID
EFI_UUID=\$(blkid -s UUID -o value ${PART_PREFIX}1)
SWAP_UUID=\$(blkid -s UUID -o value ${PART_PREFIX}2)
ROOT_UUID=\$(blkid -s UUID -o value ${PART_PREFIX}3)

cat > /etc/fstab <<FSTAB
UUID=\$EFI_UUID   /efi      vfat    defaults          0 2
UUID=\$SWAP_UUID  none      swap    sw                0 0
UUID=\$ROOT_UUID  /         ext4    noatime           0 1
FSTAB

cat > /etc/hostname <<HOST
gentoo-pc
HOST

cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   gentoo-pc.localdomain gentoo-pc
HOSTS

echo 'Italia/Roma' > /etc/timezone
ln -sf ../usr/share/zoneinfo/Europe/Rome /etc/localtime
echo "it_IT.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set it_IT.UTF-8
env-update && source /etc/profile

cat >> /etc/portage/make.conf <<MAKE
USE="-systemd"
GENTOO_MIRRORS="https://distfiles.gentoo.org"
MAKE

emerge-webrsync

eselect profile set default/linux/amd64/23.0/desktop 2>/dev/null || \
    eselect profile set default/linux/amd64/23.0 2>/dev/null || \
    echo "ATTENZIONE: seleziona manualmente un profilo con 'eselect profile list'"

echo "Europe/Rome" > /etc/timezone
ln -sf ../usr/share/zoneinfo/Europe/Rome /etc/localtime

echo "Kernel: emerge gentoo-kernel-bin (senza --ask per esecuzione automatica)"
emerge --quiet sys-kernel/gentoo-kernel-bin
emerge --quiet sys-kernel/linux-firmware sys-firmware/intel-microcode
emerge --quiet sys-firmware/sof-firmware

echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
emerge --quiet sys-boot/grub
grub-install --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

echo "root:$ROOT_PASSWORD" | chpasswd
useradd -m -G users,wheel,audio,video,usb "$USER_NAME"
echo "$USER_NAME:$USER_PASSWORD" | chpasswd

# Sudo
emerge --quiet app-admin/sudo
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/wheel

# Network (DHCP per avvio automatico)
emerge --quiet net-misc/dhcpcd
rc-update add dhcpcd default

# Servizi di sistema
emerge --quiet app-admin/sysklogd sys-process/cronie net-misc/chrony
rc-update add sysklogd default
rc-update add cronie default
rc-update add chronyd default

echo "Installazione Gentoo completata con successo!"
CHROOT_EOF

# ────────────────────────────── FINE E RIAVVIO ──────────────────────────────
messaggio "Smontaggio e riavvio del sistema"
cd /
umount -l /mnt/gentoo/dev{/shm,/pts,} 2>/dev/null || true
umount -R /mnt/gentoo
swapoff -a

echo
echo "======================================================================"
echo "Gentoo Linux installato con successo su $DISK"
echo "Rimuovi il supporto di installazione (USB/CD) prima del riavvio."
echo "======================================================================"
read -p "Premi INVIO per riavviare..."
reboot
