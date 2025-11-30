#!/bin/bash

# Script per l'installazione base di Gentoo con OpenRC, UEFI, su disco NVMe (/dev/nvme0n1).
# Partizioni: EFI (1G), Swap (8G), Root (resto).
# Lingua e tastiera in italiano, fuso orario Europe/Rome.
# Ispirato al Gentoo Handbook: https://wiki.gentoo.org/wiki/Handbook:AMD64
# Esegui questo script dal live environment di Gentoo (es. minimal ISO bootata).
# ATTENZIONE: Questo script cancellerà tutti i dati su /dev/nvme0n1! Usa con cautela.
# (C) 2005 by Nicolini Loris r3bus77@gmail.com

set -e  # Esci in caso di errore

# Funzione per mostrare messaggi
function messaggio {
    echo -e "\n=== $1 ==="
}

# Richiesta input utente
messaggio "Richiesta informazioni utente"
read -p "Inserisci la password per root: " -s ROOT_PASSWORD
echo
read -p "Inserisci il nome utente da creare: " USER_NAME
read -p "Inserisci la password per l'utente $USER_NAME: " -s USER_PASSWORD
echo

# Configurazione ambiente live
messaggio "Configurazione ambiente live"
loadkeys it  # Tastiera italiana
export LANG=it_IT.UTF-8  # Lingua italiana (assumi sia supportata nel live)

# Configurazione rete (assumi DHCP automatico, altrimenti configura manualmente)
messaggio "Configurazione rete"
dhcpcd  # Avvia DHCP su interfacce disponibili
ping -c 3 gentoo.org || { echo "Errore: Nessuna connessione internet. Configura la rete manualmente."; exit 1; }

# Preparazione disco
messaggio "Partizionamento disco (/dev/nvme0n1)"
# Crea GPT: EFI (1G), Swap (8G), Root (resto)
fdisk /dev/nvme0n1 <<EOF
g
n
1

+1G
t
1
ef
n
2

+8G
t
2
82
n
3

 
t
3
83
w
EOF

# Formattazione
messaggio "Formattazione partizioni"
mkfs.vfat -F 32 /dev/nvme0n1p1
mkswap /dev/nvme0n1p2
mkfs.ext4 /dev/nvme0n1p3

# Attivazione swap (opzionale, ma utile durante installazione)
messaggio "Attivazione swap"
swapon /dev/nvme0n1p2

# Montaggio
messaggio "Montaggio filesystems"
mkdir -p /mnt/gentoo
mount /dev/nvme0n1p3 /mnt/gentoo
mkdir -p /mnt/gentoo/efi
mount /dev/nvme0n1p1 /mnt/gentoo/efi

# Imposta data (usa NTP)
messaggio "Impostazione data"
chronyd -q

# Download stage3 (usa latest per ottenere il file corretto)
messaggio "Download stage3"
cd /mnt/gentoo
BASE_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds"
LATEST_FILE="latest-stage3-amd64-openrc.txt"
wget $BASE_URL/$LATEST_FILE
STAGE_REL_PATH=$(grep -v '^#' $LATEST_FILE | awk '{print $1}')
STAGE_FILE=$(basename $STAGE_REL_PATH)
DIGESTS_FILE=$STAGE_REL_PATH.DIGESTS
wget $BASE_URL/$STAGE_REL_PATH
wget $BASE_URL/$DIGESTS_FILE

# Verifica (SHA512)
SHA512=$(openssl dgst -r -sha512 $STAGE_FILE | cut -d' ' -f1)
grep $SHA512 $(basename $DIGESTS_FILE) || { echo "Errore: Verifica fallita."; exit 1; }

# Estrazione
messaggio "Estrazione stage3"
tar xpvf $STAGE_FILE --xattrs-include='*.*' --numeric-owner

# Copia resolv.conf
messaggio "Copia configurazione DNS"
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/

# Montaggio filesystems necessari
messaggio "Montaggio binds"
mount --types proc /proc /mnt/gentoo/proc
mount --rbind /sys /mnt/gentoo/sys
mount --make-rslave /mnt/gentoo/sys
mount --rbind /dev /mnt/gentoo/dev
mount --make-rslave /mnt/gentoo/dev
mount --bind /run /mnt/gentoo/run
mount --make-slave /mnt/gentoo/run

# Chroot e configurazione base
messaggio "Entrata in chroot e configurazione"
chroot /mnt/gentoo /bin/bash <<CHROOT_EOF
source /etc/profile
export PS1="(chroot) \$PS1"

# Configura fstab
messaggio "Configurazione /etc/fstab"
blkid > /tmp/blkid_output
EFI_UUID=\$(grep /dev/nvme0n1p1 /tmp/blkid_output | grep -oP 'UUID="\K[^"]+')
SWAP_UUID=\$(grep /dev/nvme0n1p2 /tmp/blkid_output | grep -oP 'UUID="\K[^"]+')
ROOT_UUID=\$(grep /dev/nvme0n1p3 /tmp/blkid_output | grep -oP 'UUID="\K[^"]+')

cat <<FSTAB_EOF > /etc/fstab
# <fs>                  <mountpoint>    <type>          <opts>          <dump/pass>
UUID=\$EFI_UUID         /efi            vfat            defaults        0 2
UUID=\$SWAP_UUID        none            swap            sw              0 0
UUID=\$ROOT_UUID        /               ext4            noatime         0 1
FSTAB_EOF

# Configura make.conf (base)
messaggio "Configurazione /etc/portage/make.conf"
echo 'USE=" -systemd"' >> /etc/portage/make.conf  # Assicura OpenRC
echo 'GENTOO_MIRRORS="https://distfiles.gentoo.org"' >> /etc/portage/make.conf

# Seleziona profilo OpenRC
messaggio "Selezione profilo"
eselect profile set default/linux/amd64/23.0/desktop  # Esempio base, adatta se necessario

# Aggiorna portage
messaggio "Aggiornamento mondo"
emerge-webrsync
emerge --sync --quiet
emerge --update --deep --newuse @world

# Fuso orario
messaggio "Impostazione fuso orario (Europe/Rome)"
ln -sf ../usr/share/zoneinfo/Europe/Rome /etc/localtime
echo "Europe/Rome" > /etc/timezone

# Locale
messaggio "Impostazione locale (it_IT)"
echo "it_IT.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
eselect locale set it_IT.UTF-8
env-update && source /etc/profile

# Installa kernel (dist-kernel semplice)
messaggio "Installazione kernel"
emerge --ask sys-kernel/gentoo-kernel-bin  # Prebuilt per semplicità

# Installa firmware se necessario
emerge --ask sys-kernel/linux-firmware
emerge --ask sys-firmware/sof-firmware
emerge --ask sys-firmware/intel-microcode

# Installa bootloader GRUB
messaggio "Installazione GRUB (UEFI)"
echo 'GRUB_PLATFORMS="efi-64"' >> /etc/portage/make.conf
emerge --ask sys-boot/grub
grub-install --efi-directory=/efi
grub-mkconfig -o /boot/grub/grub.cfg

# Imposta password root
messaggio "Impostazione password root"
echo "root:\$ROOT_PASSWORD" | chpasswd

# Crea utente
messaggio "Creazione utente"
useradd -m -G users,wheel -s /bin/bash \$USER_NAME
echo "\$USER_NAME:\$USER_PASSWORD" | chpasswd

# Installa tool base (logger, cron, etc.)
messaggio "Installazione tool system"
emerge --ask app-admin/sysklogd
rc-update add sysklogd default
emerge --ask sys-process/cronie
rc-update add cronie default
emerge --ask net-misc/chrony
rc-update add chronyd default

# Fine chroot
messaggio "Configurazione completata nel chroot"
CHROOT_EOF

# Uscita e reboot
messaggio "Uscita dal chroot e reboot"
cd
umount -l /mnt/gentoo/dev{/shm,/pts,}
umount -R /mnt/gentoo
swapoff -a
reboot

echo "Installazione completata! Riavvia e rimuovi il media live."
