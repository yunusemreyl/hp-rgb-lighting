# HP RGB Aydınlatma Sürücüsü (hp-rgb-lighting) Detaylı Sürücü Belgelendirmesi

Bu döküman, HP Omen ve Victus dizüstü bilgisayarlarda yer alan RGB klavye arka aydınlatma donanımını kontrol etmek üzere geliştirilen `hp-rgb-lighting.c` yardımcı Linux çekirdek modülünün (driver) iç mimarisini, veri yapılarını, fonksiyonlarını ve kullanımını detaylandırmak amacıyla hazırlanmıştır.

---

## 1. Genel Bakış ve Mimari

`hp-rgb-lighting` sürücüsü, Linux çekirdeğinde çalışan ve HP Omen/Victus dizüstü bilgisayarların WMI (Windows Management Instrumentation) ACPI arabirimi üzerinden RGB klavye bölgelerini ve diğer bazı aydınlatma durumlarını yöneten bir yardımcı sürücüdür (companion driver).

Sürücünün mimari açıdan en önemli özellikleri şunlardır:
* **Birlikte Var Olma (Coexistence):** Linux çekirdeğinde varsayılan olarak bulunan ve fan kontrolü, kısayol tuşları, güç profilleri gibi işlevleri yöneten `hp-wmi` sürücüsüyle çakışmadan **birlikte sorunsuz çalışacak şekilde** tasarlanmıştır. Bu amaçla modül, herhangi bir özel WMI GUID'i kendi adına sahiplenmez (`MODULE_ALIAS` tanımlanmamıştır). Sadece gerekli BIOS sorgularını paylaşılan GUID üzerinden gerçekleştirir.
* **Kullanıcı Alanı Arayüzü (Sysfs API):** Sürücü, kullanıcı alanından (userspace) klavye aydınlatmasını kontrol edebilmek için `/sys/devices/platform/hp-rgb-lighting/` dizini altında sanal dosyalar oluşturur.
* **Güvenli Sorgu ve Eşzamanlılık Kontrolü:** BIOS sorguları sırasında ACPI metot değerlendirmeleri ve tampon bellek paylaşımları muteks (`mutex`) kilitleri ile güvence altına alınmıştır.

---

## 2. Sabitler, Enümrasyonlar ve Veri Yapıları

Kod içerisinde kullanılan tüm temel tanımlamalar, komut tipleri ve veri yapıları aşağıda açıklanmıştır:

### A. WMI GUID
```c
#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
```
Bu GUID, HP BIOS'unun WMI üzerinden sunduğu kontrol metotlarına erişmek için kullanılan benzersiz tanıtıcıdır. `wmi_evaluate_method` çağrılarında hedef adres olarak kullanılır.

### B. `enum hp_wmi_command` (WMI Komut Tipleri)
HP BIOS WMI arabiriminin hangi genel işlemi gerçekleştireceğini belirten ana komut kodlarıdır:
* **`HPWMI_READ` (`0x01`):** BIOS'tan veri okuma işlemlerinde kullanılır (Örn: Windows kilidi durumunu okumak).
* **`HPWMI_WRITE` (`0x02`):** BIOS'a veri yazma/değiştirme işlemlerinde kullanılır.
* **`HPWMI_BACKLIGHT` (`0x20009`):** Arka aydınlatma rengini okumak veya yazmak için kullanılan özel kategori komutudur.
* **`HPWMI_GAMING_KEY` (`0x2000B`):** Windows kilidi (Win Lock / Gaming Key) özelliğine erişmek için kullanılan komuttur.

### C. `enum hp_wmi_backlight_commandtype` (Aydınlatma Alt Komut Tipleri)
`HPWMI_BACKLIGHT` ana komutu altında, gerçekleştirilecek işlemi detaylandıran alt sorgu kodlarıdır:
* **`HPWMI_COLOR_GET_QUERY` (`0x02`):** Mevcut RGB renk tablosunu BIOS'tan çekmek için kullanılır.
* **`HPWMI_COLOR_SET_QUERY` (`0x03`):** Belirlenen yeni renk tablosunu BIOS'a yazarak klavye renklerini değiştirmek için kullanılır.
* **`HPWMI_BRIGHTNESS_GET_QUERY` (`0x04`):** Klavyenin ana parlaklık (açık/kapalı) durumunu okumak için kullanılır.
* **`HPWMI_BRIGHTNESS_SET_QUERY` (`0x05`):** Klavye parlaklığını açmak veya kapatmak için kullanılır.

### D. BIOS İletişim Yapıları
Sürücünün ACPI BIOS ile veri alışverişi yaparken kullandığı tampon bellek düzenidir:

```c
struct bios_args {
  u32 signature;      // BIOS doğrulaması için imza (Her zaman 0x55434553 / "SECU")
  u32 command;        // Ana komut tipi (enum hp_wmi_command)
  u32 commandtype;    // Alt sorgu/komut tipi (enum hp_wmi_backlight_commandtype)
  u32 datasize;       // data[] dizisine aktarılan gerçek girdi verisinin bayt boyutu
  u8 data[];          // Değişken uzunluklu girdi veri tamponu
};
```

```c
struct bios_return {
  u32 sigpass;        // BIOS tarafından dönen imza doğrulaması sonucu
  u32 return_code;    // Sorgunun başarı durumu (0 = Başarılı, sıfır dışı = Hata kodu)
};
```

---

## 3. Yardımcı Fonksiyonlar

### `encode_outsize_for_pvsz`
```c
static inline int encode_outsize_for_pvsz(int outsize)
```
* **Görevi:** BIOS'un çıktı olarak üreteceği veri boyutuna (`outsize`) göre uygun ACPI Metot Kimliğini (Method ID) belirler.
* **Çalışma Mantığı:** ACPI BIOS, çağrılan metodun ID'sine göre tampon belleğin boyutunu tahmin eder. Boyut aralıklarına göre `1` ile `5` arasında bir değer döner:
  - `outsize > 4096` ise geçersiz kabul edilerek `-EINVAL` dönülür.
  - Boyuta göre eşleşen metot ID'leri sırasıyla: `> 1024` $\rightarrow$ 5, `> 128` $\rightarrow$ 4, `> 4` $\rightarrow$ 3, `> 0` $\rightarrow$ 2, `0` $\rightarrow$ 1.

### `hp_wmi_perform_query`
```c
static int hp_wmi_perform_query(int query, enum hp_wmi_command command, void *buffer, int insize, int outsize)
```
Sürücünün kalbidir. BIOS ile tüm WMI iletişimini tek bir güvenli çatı altında toplar:
1. `encode_outsize_for_pvsz` ile çıktı boyutu için ACPI metot ID'sini (`mid`) bulur.
2. Girdi verisini (`insize`) içerecek boyutta ve en az 128 bayt olacak şekilde dinamik bir `struct bios_args` nesnesi tahsis eder (`kzalloc`).
3. Yapı içerisine `0x55434553` (ASCII: `SECU`) imzasını, komut ve alt-komut parametrelerini yerleştirir; girdi verisini `memcpy` ile kopyalar.
4. Çakışmaları önlemek için `hp_wmi_query_mutex` kilidini alır ve `wmi_evaluate_method` çekirdek fonksiyonunu çağırarak ACPI metodunu çalıştırır.
5. ACPI yanıtını aldıktan sonra nesne tipinin `ACPI_TYPE_BUFFER` olduğunu doğrular.
6. Yanıt tamponunun (`bios_return`) boyutunu ve yapısını kontrol eder. BIOS hata kodu döndüyse (`return_code != 0`), bu hata kodunu döner.
7. Başarılı ise, dönen veriyi güvenli bir şekilde `memcpy` ile parametre olarak gelen `buffer` alanına kopyalar. Tahsis edilen dinamik bellekleri serbest bırakır.

---

## 4. Sysfs Arayüzü (Kullanıcı Alanı API'si)

Sürücü yüklendiğinde, `/sys/devices/platform/hp-rgb-lighting/` dizini altında kullanıcı alanı programlarının okuma ve yazma yapabileceği kontrol arayüzleri oluşturulur. Tüm arayüzlerde eşzamanlı yazma ve okuma işlemlerini korumak için `rgb_mutex` kilidi kullanılır.

### A. Klavye RGB Bölgeleri (`zone0` - `zone7`)
Sürücü maksimum **8 adet bağımsız RGB bölgesini** destekler.
* **Erişim Tipi:** Okunabilir ve Yazılabilir (`0644`).
* **Veri Formatı:** Büyük harflerle 6 karakterli 24-bit Hex RGB renk dizisi (Örn: Kırmızı için `"FF0000"`, Yeşil için `"00FF00"`).
* **Gösterim (`zone_show`):** Rengi okumak için BIOS'tan 128 baytlık (`COLOR_TABLE_SIZE`) renk tablosu çekilir. RGB verisi bu tablonun **25. baytından (`COLOR_OFFSET`)** itibaren başlar. Her bölge 3 bayt (Kırmızı, Yeşil, Mavi sırasıyla) yer kaplar. İlgili bölgenin RGB değerleri okunup formatlanarak ekrana yazdırılır.
* **Kaydetme (`zone_store`):** Girilen Hex renk kodu çözümlenerek önce mevcut renk tablosu BIOS'tan çekilir, ardından ilgili bölgenin 3 baytlık verisi (`tbl[25 + zone * 3]`) güncellenir. Son olarak `HPWMI_COLOR_SET_QUERY` çağrısıyla tüm tablo BIOS'a geri yazılır.

### B. Parlaklık Kontrolü (`brightness`)
* **Erişim Tipi:** Okunabilir ve Yazılabilir (RW).
* **Değerler:**
  - `1`: Klavye aydınlatmasını açar (BIOS seviyesinde `0xE4` komut verisi gönderilir).
  - `0`: Klavye aydınlatmasını tamamen kapatır (BIOS seviyesinde `0x64` komut verisi gönderilir).
* **Gösterim (`brightness_show`):** BIOS'tan mevcut durum sorgulanır. Gelen veri `0xE4` ise `1` (Açık), aksi takdirde `0` (Kapalı) döner.
* **Kaydetme (`brightness_store`):** Kullanıcı `1` yazarsa `0xE4`, `0` yazarsa `0x64` değeri BIOS'a gönderilerek arka ışık durumu değiştirilir.

### C. Windows Kilidi / Oyun Modu (`win_lock`)
* **Erişim Tipi:** Okunabilir ve Yazılabilir (RW).
* **Görevi:** Oyun esnasında Windows tuşunun kazara çalışmasını engellemek üzere klavyenin Windows Kilidi donanımını tetikler.
* **Değerler:**
  - `1`: Windows tuşu kilitlenir (BIOS seviyesinde `0x01` gönderilir).
  - `0`: Windows tuşu kilidi açılır (BIOS seviyesinde `0x00` gönderilir).

---

## 5. Platform Aygıt Yaşam Döngüsü

### A. Modül Yüklenmesi (`hp_rgb_lighting_init`)
Sürücü sisteme yüklendiğinde (`insmod` veya `modprobe` ile):
1. Sistemde `HPWMI_BIOS_GUID` adresine sahip bir WMI BIOS arayüzünün varlığı `wmi_has_guid` ile kontrol edilir. Bulunamazsa `-ENODEV` (Cihaz yok) hatası ile sonlandırılır (HP dışı sistemlerde yüklenmeyi engeller).
2. Basit bir platform aygıtı olarak `hp-rgb-lighting` ismiyle çekirdeğe tescil edilir (`platform_device_register_simple`).
3. Başarıyla tescil edildikten sonra `sysfs_create_groups` fonksiyonu ile tüm sysfs öznitelik grupları (`zone0-7`, `brightness`, `win_lock`) bu platform cihazına bağlanarak kullanıcı arayüzü aktif hale getirilir.

### B. Modül Kaldırılması (`hp_rgb_lighting_exit`)
Sürücü sistemden kaldırıldığında (`rmmod` ile):
1. `sysfs_remove_groups` çağrılarak sanal sysfs arayüz dosyaları temizlenir.
2. Platform aygıtının kaydı silinir (`platform_device_unregister`) ve ayrılan sistem kaynakları güvenle iade edilir.

---

## 6. Derleme, Kurulum ve Kullanım Kılavuzu

### Derleme İçin Gerekli `Makefile` Örneği
Sürücüyü derlemek için aynı dizinde aşağıdaki içerikle bir `Makefile` oluşturulmalıdır:

```makefile
obj-m += hp-rgb-lighting.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
```

### Derleme ve Yükleme Adımları
Terminal üzerinden sürücüyü derlemek ve çekirdeğe yüklemek için şu komutları sırasıyla çalıştırın:

```bash
# 1. Kaynak kodu derleyin
make

# 2. Çekirdek modülünü sisteme yükleyin
sudo insmod hp-rgb-lighting.ko

# 3. Sürücünün başarıyla yüklendiğini çekirdek günlüklerinden (dmesg) doğrulayın
dmesg | grep hp-rgb-lighting
```

### Kontrol ve Test Komutları

```bash
# Tüm sysfs dosyalarını ve izinlerini listeleyin
ls -la /sys/devices/platform/hp-rgb-lighting/

# Klavye aydınlatmasını açın
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness

# 1. Bölgeyi Kırmızı yapın
echo "FF0000" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone0

# 2. Bölgeyi Yeşil yapın
echo "00FF00" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone1

# Windows Tuşu Kilidini Aktif Edin
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock

# Mevcut 1. Bölge rengini okuyun
cat /sys/devices/platform/hp-rgb-lighting/zone0
```
