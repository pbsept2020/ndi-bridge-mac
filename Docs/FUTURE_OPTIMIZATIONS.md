# Optimisations Futures - NDI Bridge Mac

## Statut : À explorer quand le besoin se fera sentir

Ces optimisations ne sont pas prioritaires car le pipeline actuel fonctionne bien.
Elles sont documentées ici pour référence future.

---

## 1. Accélération GPU via Metal

### Contexte
Actuellement les conversions de format pixel (BGRA ↔ UYVY ↔ NV12) se font en CPU.
Le GPU Apple Silicon pourrait les accélérer via Metal Compute Shaders.

### Tâches candidates
| Tâche | Impact estimé |
|-------|---------------|
| Conversion BGRA → NV12 | Moyen |
| Conversion NV12 → UYVY | Moyen |
| Scaling/resize | Fort si utilisé |
| Deinterlacing | Fort si sources entrelacées |

### Ressources
- MCP tool `ivs_ndi_get_code_example` avec `metal_shader` et `metal_shader_bilinear`
- WWDC sessions sur VideoToolbox + Metal interop

### Test à faire
Mesurer CPU usage actuel avec Instruments pour identifier les hotspots réels.

---

## 2. Zero-Copy Pipeline

### Contexte
Le M1 a une mémoire unifiée CPU/GPU. En théorie, on peut éviter les copies mémoire
entre NDI, VideoToolbox et Metal en utilisant des IOSurface partagées.

### Architecture cible
```
NDI CVPixelBuffer (IOSurface-backed)
        ↓ (zero-copy)
VideoToolbox Encode
        ↓ (zero-copy)  
Metal texture (si traitement GPU)
        ↓ (zero-copy)
NDI Send
```

### Prérequis
- CVPixelBuffer avec kCVPixelBufferIOSurfacePropertiesKey
- Pool de buffers pré-alloués
- Synchronisation GPU fence

---

## 3. Double Buffering pour éliminer les stalls GPU

### Contexte
Si on utilise Metal, le GPU et CPU peuvent se bloquer mutuellement en attendant
les ressources. Le double-buffering permet au CPU de préparer le frame N+1
pendant que le GPU traite le frame N.

### Voir
- MCP tool `ivs_ndi_get_optimizations` category `double_buffering`

---

## 4. Passthrough HX (sans ré-encodage)

### Contexte
Si la source NDI est déjà en NDI|HX (H.264/H.265), et qu'on veut sortir en HX,
on pourrait faire un simple passthrough sans decode/encode.

### Économie
- Zéro utilisation Media Engine
- Latence minimale
- CPU quasi nul

### Condition
- Détecter le format source (FourCC)
- Vérifier compatibilité avec format sortie demandé

---

## Priorité de test

1. **Mesurer d'abord** - Utiliser Instruments pour voir si on a vraiment un problème
2. **Metal conversions** - Si CPU > 30% sur conversions pixel
3. **Zero-copy** - Si copies mémoire sont le bottleneck
4. **Passthrough HX** - Si use case spécifique le demande

---

## 5. Sortie NDI|HX (H.264/H.265 compressé)

### Statut : ⛔ BLOQUÉ - Nécessite NDI Advanced SDK

### Contexte
Pour émettre des flux NDI compressés (NDI|HX2/HX3), il faut utiliser les fonctions
`NDIlib_send_send_video_compressed()` et la structure `NDIlib_compressed_packet_t`.
Ces APIs ne sont **pas disponibles** dans le SDK Standard gratuit.

| SDK | Prix | NDI Full (send) | NDI|HX (send) | NDI|HX (receive) |
|-----|------|-----------------|---------------|------------------|
| **Standard** | Gratuit | ✅ | ❌ | ✅ |
| **Advanced** | Commercial | ✅ | ✅ | ✅ |

### Use case visé
Distribution institutionnelle (universités, hôtels) vers 50-100 endpoints :
- NDI Full : ~125 Mbps → sature un switch 1Gbps à 8 streams
- NDI|HX H.264 : ~8-15 Mbps → 50-100 streams possibles
- NDI|HX H.265 : ~5-10 Mbps → encore meilleure scalabilité

### Comment obtenir le NDI Advanced SDK

**Option 1 : Trial gratuit**
1. Page officielle : https://ndi.video/for-developers/ndi-advanced/
2. Formulaire Software : https://ndi.video/for-developers/ndi-advanced/software/request/
3. Formulaire Cloud : https://ndi.video/for-developers/ndi-advanced/cloud/request/
4. Décrire le use case : "WAN bridge for institutional broadcast"

**Option 2 : Licence commerciale**
- Contact : licensing@ndi.video
- Demander un "vendor ID" pour l'entreprise
- Pricing : volume-based (plus tu vends, moins tu paies)

**Avantages inclus avec Advanced**
- Support technique dédié Vizrt
- Éligibilité certification "NDI Certified"
- Co-marketing avec NDI
- FPGA reference designs (AMD Xilinx, Intel Altera)

### ⚠️ Licences brevets H.264/H.265

Même avec le SDK Advanced, l'utilisation **commerciale** de H.264/H.265 peut
nécessiter des licences supplémentaires auprès des patent pools :
- H.264 : MPEG LA (http://www.mpegla.com)
- H.265 : HEVC Advance (http://www.hevcadvance.com)

Usage personnel/non-commercial généralement exempté.

### Alternatives sans Advanced SDK

1. **Garder NDI Full** pour LAN haute performance (déjà fonctionnel)
2. **Recommander NDI Bridge officiel** de Vizrt pour distribution WAN
3. **Réduire framerate/résolution** : 30fps au lieu de 60fps, 720p au lieu de 1080p

### TODO si on obtient le SDK Advanced

```swift
// Structure à implémenter
let compressedPacket = NDIlib_compressed_packet_t(
    version: 0,
    fourCC: NDIlib_FourCC_type_H264,  // ou HEVC
    pts: timestamp,
    dts: timestamp,
    flags: isKeyframe ? NDIlib_compressed_packet_flags_keyframe : 0,
    data: encodedData,
    data_size: encodedData.count,
    extra_data: spsAndPps,           // SPS/PPS pour H.264, VPS/SPS/PPS pour HEVC
    extra_data_size: spsAndPps.count
)

NDIlib_send_send_video_compressed(sender, &compressedPacket)
```

- Étendre `CNDIWrapper` pour exposer les APIs compressed
- Ajouter paramètre `--output-format [full|hx264|hx265]`
- Utiliser VideoToolbox pour l'encodage H.264/H.265 (Media Engine hardware)
- Extraire SPS/PPS/VPS des CMSampleBuffer pour extra_data

---

## Notes

Dernière mise à jour : Janvier 2025
Ces optimisations sont documentées suite à l'analyse du pipeline M1.
Le Media Engine gère déjà encode/decode H.264/H.265 en hardware.

**Section HX ajoutée** : Janvier 2025 - En attente accès NDI Advanced SDK.
