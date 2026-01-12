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

## Notes

Dernière mise à jour : Janvier 2025
Ces optimisations sont documentées suite à l'analyse du pipeline M1.
Le Media Engine gère déjà encode/decode H.264/H.265 en hardware.
