# HP RGB Lighting Driver Documentation Hub / Sürücü Dökümantasyon Merkezi

Welcome to the official developer and user documentation for the `hp-rgb-lighting` Linux companion driver. This driver provides a dedicated interface to control the RGB keyboard backlights on HP Omen and Victus laptops via WMI without interfering with the main `hp-wmi` driver.

HP Omen ve Victus dizüstü bilgisayarların RGB klavye arka aydınlatmasını kontrol etmek amacıyla WMI protokolünü kullanan `hp-rgb-lighting` yardımcı Linux sürücüsünün resmi geliştirici ve kullanıcı dökümantasyon merkezine hoş geldiniz.

---

## 🌐 Select Language / Dil Seçin

Please choose your preferred language to read the highly-detailed technical documentation:

Lütfen son derece detaylı hazırlanmış teknik dökümantasyonu okumak için tercih ettiğiniz dili seçin:

*   **[Türkçe (Turkish)](file:///c:/Users/yunusemreyl/Desktop/documentation/docs/documentation_tr.md)** - Detaylı Türkçe Sürücü Dökümantasyonu
*   **[English (English)](file:///c:/Users/yunusemreyl/Desktop/documentation/docs/documentation_en.md)** - Detailed English Driver Documentation
*   **[简体中文 (Simplified Chinese)](file:///c:/Users/yunusemreyl/Desktop/documentation/docs/documentation_zh.md)** - 简体中文 详细驱动程序文档
*   **[Español (Spanish)](file:///c:/Users/yunusemreyl/Desktop/documentation/docs/documentation_es.md)** - Documentación Detallada del Controlador en Español
*   **[Français (French)](file:///c:/Users/yunusemreyl/Desktop/documentation/docs/documentation_fr.md)** - Documentation Détaillée du Pilote en Français
*   **[Deutsch (German)](file:///c:/Users/yunusemreyl/Desktop/documentation/docs/documentation_de.md)** - Detaillierte Treiberdokumentation auf Deutsch

---

## 🛠️ Quick Status Overview / Hızlı Durum Özeti

The `hp-rgb-lighting` driver establishes a platform device and exposes a clean interface under the Linux sysfs virtual file system:

`hp-rgb-lighting` sürücüsü, bir platform aygıtı oluşturarak Linux sysfs sanal dosya sistemi altında temiz bir kontrol arayüzü sunar:

| Path / Yol | Access / Erişim | Description / Açıklama | Values / Değerler |
| :--- | :--- | :--- | :--- |
| `.../zone0` to `.../zone7` | Read / Write | RGB Keyboard zones / RGB Klavye bölgeleri | 24-bit Hex RGB (e.g. `FF0000` for Red) |
| `.../brightness` | Read / Write | Backlight Master Toggle / Ana Parlaklık Anahtarı | `1` (ON/Açık), `0` (OFF/Kapalı) |
| `.../win_lock` | Read / Write | Gaming Key (Win Lock) / Oyun Tuşu (Win Kilidi) | `1` (Locked/Kilitli), `0` (Unlocked/Açık) |

*System Path / Sistem Yolu:* `/sys/devices/platform/hp-rgb-lighting/`
