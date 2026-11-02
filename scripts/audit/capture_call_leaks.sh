#!/bin/bash
# ==============================================================================
# SCRIPT D'AUDIT MANUEL — vérifie qu'un appel Murmure ne fuit aucune IP réelle
# (voir docs/CALLS_ARCHITECTURE.md : c'est la SEULE étape qui sépare encore ce code de
# « appels activés hors mode direct », et elle doit être faite sur un vrai appareil — personne
# ne peut la cocher depuis un bac à sable de développement, ce script y compris).
#
# Corrige une proposition reçue dans cette conversation qui contenait trois défauts réels :
#
# 1. `kill -9` sur tcpdump : SIGKILL ne lui laisse AUCUNE chance de clore proprement le fichier
#    .pcap (flush des buffers, écriture de l'en-tête final) — risque réel de capture tronquée ou
#    illisible, soit exactement le résultat qu'on NE PEUT PAS se permettre pour un audit dont la
#    conclusion est "aucune fuite détectée". On envoie plutôt SIGTERM/SIGINT, que tcpdump gère
#    explicitement pour fermer le fichier avant de quitter.
# 2. Le filtre d'analyse (`ip.addr != $SERVER_IP and udp`) ne cible pas spécifiquement
#    l'appareil de test : capturer toute une interface fait aussi apparaître le DNS, le mDNS
#    (découverte de service), le DHCP, le trafic d'autres appareils du même réseau, etc. — du
#    bruit qui noierait une vraie fuite au lieu de la faire ressortir. On filtre maintenant
#    explicitement sur l'IP de l'appareil testé.
# 3. LE PLUS IMPORTANT, absent de la proposition reçue : sur un Wi-Fi WPA2/WPA3 d'infrastructure
#    ordinaire, un ordinateur simplement « relié au même réseau » ne peut PAS, en général,
#    intercepter le trafic unicast d'un AUTRE appareil (chaque association utilise une clé par
#    paire, pas une clé partagée reniflable par un tiers passif) — sauf réseau ouvert/WEP (à ne
#    jamais utiliser), point d'accès que vous contrôlez vous-même en pont avec capture sur
#    l'interface pontée, ou matériel de capture promiscuous dédié. Suivre la proposition reçue
#    à la lettre risque de produire une capture qui ne contient JAMAIS le trafic du téléphone —
#    et donc une fausse conclusion "aucune fuite" qui ne prouve rien du tout. Voir la section
#    « Comment capturer RÉELLEMENT le trafic du téléphone » plus bas : ce script suppose que
#    vous avez mis en place une des méthodes qui y sont décrites, il ne le fait pas pour vous.
#
# ==============================================================================
set -euo pipefail

INTERFACE="wlan0"   # Interface qui voit RÉELLEMENT le trafic du téléphone — voir la section
                     # ci-dessous. Si vous USB-tetherez le téléphone à cette machine, c'est
                     # l'interface réseau créée par ce tethering (ex. "usb0", "enp0s20u1"), PAS
                     # le Wi-Fi de l'ordinateur lui-même.
DEVICE_IP="CHANGE_ME_IP_DU_TELEPHONE_SUR_CE_RESEAU"   # IP du téléphone pendant le test.
SERVER_IP="CHANGE_ME_IP_DE_VOTRE_SERVEUR_COTURN"      # IP publique du serveur coturn.
OUTPUT_FILE="audit_call_capture.pcap"

cat <<EOF
=== Comment capturer RÉELLEMENT le trafic du téléphone ===
Sur un Wi-Fi WPA2/WPA3 d'infrastructure ordinaire, être "sur le même réseau" ne suffit PAS à
voir le trafic d'un autre appareil. Choisissez l'une de ces méthodes avant de lancer ce script :

  (a) USB tethering : partagez la connexion internet de cet ordinateur AU téléphone via USB
      (ou l'inverse, selon votre matériel), de façon à ce que TOUT le trafic du téléphone
      transite physiquement par cette machine. C'est la méthode la plus simple à mettre en
      place sans matériel supplémentaire.
  (b) Point d'accès que vous contrôlez vous-même (ex. un routeur sous OpenWRT/Linux, ou un
      partage de connexion depuis un second ordinateur Linux faisant office d'AP) : lancez la
      capture sur l'interface pontée (bridge) de cet AP, où tout le trafic des clients associés
      transite réellement en clair avant le routage.
  (c) Capture directement sur le téléphone : une application comme PCAPdroid (F-Droid/Play
      Store, ne nécessite pas root — elle utilise une VPN locale pour intercepter le trafic de
      l'appareil lui-même) exporte un .pcap que vous pouvez analyser avec les mêmes commandes
      tshark que ci-dessous. C'est la méthode la plus fiable : elle capture le trafic à la
      source, sans dépendre de la topologie Wi-Fi du moment.

Ce script suppose l'option (a) ou (b) (capture sur une interface qui voit vraiment le
téléphone). Pour l'option (c), passez directement le .pcap exporté à la section "Analyse"
plus bas (ignorez la partie tcpdump de ce script).
EOF
echo
read -r -p "Appuyez sur [ENTRÉE] une fois prêt (interface $INTERFACE configurée pour voir le téléphone à $DEVICE_IP)..."

echo "[*] Capture sur $INTERFACE — trafic légitime attendu UNIQUEMENT vers $SERVER_IP:5349."
echo "[!] Tout paquet UDP/STUN de $DEVICE_IP vers une IP autre que $SERVER_IP = fuite potentielle."

sudo tcpdump -i "$INTERFACE" -w "$OUTPUT_FILE" "host $DEVICE_IP" &
TCPDUMP_PID=$!

echo "[*] Capture en cours (PID $TCPDUMP_PID). Passez l'appel sur Murmure maintenant."
read -r -p "Appuyez sur [ENTRÉE] pour arrêter la capture et lancer l'analyse..."

# SIGTERM (pas -9) : laisse tcpdump fermer proprement le fichier .pcap.
sudo kill -TERM "$TCPDUMP_PID"
wait "$TCPDUMP_PID" 2>/dev/null || true

echo "[*] Analyse de $OUTPUT_FILE"
echo "------------------------------------------------------------------------"

echo "[🔍] Requêtes STUN (ne doivent JAMAIS apparaître — voir docs/CALLS_ARCHITECTURE.md) :"
tshark -r "$OUTPUT_FILE" -Y "stun" 2>/dev/null || echo "Aucun paquet STUN détecté."

echo
echo "[🔍] Trafic UDP du téléphone ($DEVICE_IP) vers une IP AUTRE que le serveur coturn :"
tshark -r "$OUTPUT_FILE" -Y "ip.src == $DEVICE_IP and udp and ip.dst != $SERVER_IP" \
  -T fields -e ip.dst -e udp.dstport 2>/dev/null | sort -u || true
echo "(une ligne ici = fuite potentielle à examiner manuellement dans Wireshark — DNS/NTP"
echo " normaux exceptés ; le trafic DE SIGNALISATION Matrix, lui, doit passer par le serveur"
echo " Conduit en TCP/HTTPS, jamais en UDP — tout UDP hors coturn pendant un appel est suspect)"

echo "------------------------------------------------------------------------"
echo "[*] Capture complète : $OUTPUT_FILE — ouvrez-la dans Wireshark pour inspection visuelle."
echo "[*] Cette analyse automatique est une première passe, pas une preuve suffisante à elle"
echo "    seule : relisez manuellement la capture avant de considérer l'étanchéité vérifiée."
