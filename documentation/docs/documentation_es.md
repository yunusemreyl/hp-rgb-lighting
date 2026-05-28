# Controlador de Iluminación HP RGB (hp-rgb-lighting) Documentación Detallada del Controlador

Este documento proporciona una descripción detallada de la arquitectura interna, las estructuras de datos, las funciones clave y la guía de uso del módulo complementario del núcleo de Linux `hp-rgb-lighting.c`. Este controlador gestiona la retroiluminación RGB por zonas del teclado y los atributos asociados para portátiles HP Omen y Victus a través de ACPI/WMI.

---

## 1. Descripción General y Arquitectura

El módulo `hp-rgb-lighting` es un controlador complementario y ligero diseñado específicamente para controlar la retroiluminación RGB de los teclados de portátiles HP Omen y Victus.

Decisiones clave de diseño de la arquitectura:
* **Coexistencia Diseñada (Coexistence by Design):** El controlador funciona de forma conjunta con el controlador estándar del núcleo `hp-wmi` (que gestiona perfiles térmicos, monitoreo de hardware, control de ventiladores, teclas rápidas y rfkill). Para evitar conflictos y no reclamar la interfaz WMI de forma exclusiva, este controlador complementario **no** registra ningún alias WMI (`MODULE_ALIAS("wmi:...")`). En su lugar, realiza consultas dinámicas a los métodos de la BIOS utilizando el GUID compartido de la BIOS de HP.
* **Interfaz Sysfs en Espacio de Usuario:** El módulo expone un conjunto de archivos virtuales bajo `/sys/devices/platform/hp-rgb-lighting/` permitiendo a utilidades en espacio de usuario o scripts de control consultar y configurar los colores y estados del teclado.
* **Seguridad de Hilos y Concurrencia:** Todas las evaluaciones de métodos WMI se sincronizan mediante mutexes del núcleo (`hp_wmi_query_mutex` y `rgb_mutex`) para evitar colisiones de escritura simultáneas en el intérprete ACPI subyacente.

---

## 2. Constantes, Enumeraciones y Estructuras de Datos

A continuación se detalla la descripción de las constantes, comandos y estructuras principales del módulo:

### A. WMI GUID
```c
#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
```
El GUID único de WMI utilizado para comunicarse con la interfaz BIOS propietaria de HP. Es la dirección de enrutamiento principal hacia el firmware ACPI.

### B. `enum hp_wmi_command` (Códigos de Comando Primarios de WMI)
Especifica el tipo general de transacción solicitada a la BIOS de HP:
* **`HPWMI_READ` (`0x01`):** Inicia una consulta de lectura para obtener datos de estado de la BIOS (por ejemplo, el estado del bloqueo de Windows).
* **`HPWMI_WRITE` (`0x02`):** Inicia una consulta de escritura para modificar configuraciones o variables de la BIOS.
* **`HPWMI_BACKLIGHT` (`0x20009`):** Categoría de comando específica para leer o escribir colores y patrones de la retroiluminación.
* **`HPWMI_GAMING_KEY` (`0x2000B`):** Comando dedicado a controlar características de juego especiales, como el bloqueo de la tecla de Windows (Win Lock).

### C. `enum hp_wmi_backlight_commandtype` (Subcomandos de Retroiluminación)
Subconsultas utilizadas bajo el comando primario `HPWMI_BACKLIGHT` para especificar operaciones de iluminación exactas:
* **`HPWMI_COLOR_GET_QUERY` (`0x02`):** Recupera la tabla completa de mapas de color actualmente activos en la BIOS.
* **`HPWMI_COLOR_SET_QUERY` (`0x03`):** Envía la tabla completa de mapas de color modificada de vuelta a la BIOS, aplicando los nuevos colores al hardware.
* **`HPWMI_BRIGHTNESS_GET_QUERY` (`0x04`):** Recupera el estado del interruptor maestro de retroiluminación del teclado.
* **`HPWMI_BRIGHTNESS_SET_QUERY` (`0x05`):** Configura el estado del interruptor maestro (encendido/apagado) de la retroiluminación.

### D. Estructuras de Comunicación BIOS
La distribución en memoria de los búferes enviados y recibidos a través de la interfaz ACPI/WMI:

```c
struct bios_args {
  u32 signature;      // Firma de verificación de seguridad. Debe ser 0x55434553 (ASCII para "SECU").
  u32 command;        // El código de comando primario (enum hp_wmi_command).
  u32 commandtype;    // El subcomando/tipo de consulta (enum hp_wmi_backlight_commandtype).
  u32 datasize;       // Tamaño exacto en bytes de la carga útil copiada en el búfer data[].
  u8 data[];          // Matriz de carga útil flexible y de longitud variable.
};
```

```c
struct bios_return {
  u32 sigpass;        // Código de validación de firma devuelto por la BIOS.
  u32 return_code;    // Código de resultado: 0 para éxito, un valor diferente indica un error de BIOS.
};
```

---

## 3. Funciones Auxiliares Clave

### `encode_outsize_for_pvsz`
```c
static inline int encode_outsize_for_pvsz(int outsize)
```
* **Propósito:** Mapea el tamaño de búfer de salida esperado (`outsize`) al ID de Método ACPI correspondiente.
* **Principio:** La interfaz HP WMI utiliza métodos ACPI virtuales numerados del 1 al 5 en función del volumen de memoria necesario para almacenar la respuesta.
* **Comportamiento:**
  - Devuelve `-EINVAL` si `outsize > 4096`.
  - Devuelve los ID de Método correspondientes según el tamaño: `> 1024` $\rightarrow$ 5, `> 128` $\rightarrow$ 4, `> 4` $\rightarrow$ 3, `> 0` $\rightarrow$ 2, `0` $\rightarrow$ 1.

### `hp_wmi_perform_query`
```c
static int hp_wmi_perform_query(int query, enum hp_wmi_command command, void *buffer, int insize, int outsize)
```
La función central del controlador a través de la cual se serializan y procesan todas las llamadas WMI/ACPI:
1. Invoca `encode_outsize_for_pvsz` para obtener el ID de Método ACPI adecuado (`mid`).
2. Reserva dinámicamente memoria para la estructura `struct bios_args` usando `kzalloc` con el tamaño de entrada requerido (asegurando un relleno mínimo de 128 bytes).
3. Establece la firma `"SECU"` (`0x55434553`), los parámetros del comando, el tamaño de la carga útil, y copia los datos de entrada.
4. Adquiere el mutex `hp_wmi_query_mutex` para garantizar accesos serializados y exclusivos a la BIOS.
5. Llama a `wmi_evaluate_method` pasando el GUID de la BIOS, el ID del método, los argumentos de entrada y la estructura de salida.
6. Valida que el tipo de objeto ACPI devuelto sea `ACPI_TYPE_BUFFER` y realiza verificaciones de límites de memoria.
7. Analiza `struct bios_return` para comprobar si hay códigos de error devueltos por la BIOS.
8. En caso de éxito, copia la carga útil devuelta al parámetro `buffer` y libera la memoria del núcleo previamente asignada.

---

## 4. Interfaz Sysfs (API del Espacio de Usuario)

Una vez cargado el controlador, expone la ruta `/sys/devices/platform/hp-rgb-lighting/` en el sistema de archivos virtual sysfs. Todas las operaciones de lectura y escritura en los atributos virtuales utilizan el mutex `rgb_mutex` para prevenir condiciones de carrera.

### A. Zonas RGB del Teclado (`zone0` a `zone7`)
Permite configurar de forma independiente hasta **8 zonas de iluminación** del teclado.
* **Permisos:** Lectura y Escritura (`0644`).
* **Formato de datos:** Una cadena hexadecimal de 6 caracteres en mayúsculas (formato RGB de 24 bits), por ejemplo, `"FF0000"` para rojo puro, `"00FF00"` para verde puro.
* **Lectura (`zone_show`):** Consulta a la BIOS la tabla de colores de 128 bytes (`COLOR_TABLE_SIZE`) mediante `HPWMI_COLOR_GET_QUERY`. Los datos RGB comienzan a partir del **byte 25 de desplazamiento (`COLOR_OFFSET`)**. Cada zona utiliza exactamente 3 bytes (Rojo, Verde, Azul en orden consecutivo). El método extrae y formatea estos valores en formato hexadecimal.
* **Escritura (`zone_store`):** Procesa la cadena hexadecimal del usuario. Primero descarga la tabla de colores activa de la BIOS, modifica los 3 bytes de la zona específica (`tbl[25 + zone * 3 + 0/1/2]`), y vuelve a escribir la tabla completa en la BIOS usando `HPWMI_COLOR_SET_QUERY`.

### B. Control de Brillo Maestro (`brightness`)
* **Permisos:** Lectura y Escritura (RW).
* **Valores Admitidos:**
  - `1`: Enciende la retroiluminación del teclado (se envía el código BIOS `0xE4`).
  - `0`: Apaga por completo la retroiluminación (se envía el código BIOS `0x64`).
* **Lectura (`brightness_show`):** Consulta el estado de brillo de la BIOS. Devuelve `1` si el código de estado es `0xE4`, de lo contrario devuelve `0`.
* **Escritura (`brightness_store`):** Envía `0xE4` a la BIOS para encender la luz o `0x64` para apagarla.

### C. Bloqueo de Tecla Windows / Gaming Key (`win_lock`)
* **Permisos:** Lectura y Escritura (RW).
* **Propósito:** Activa o desactiva la función física de bloqueo de la tecla de Windows del teclado, previniendo salidas accidentales del entorno de juego al escritorio.
* **Valores Admitidos:**
  - `1`: Bloquea la tecla Windows (envía `0x01` a la BIOS).
  - `0`: Desbloquea la tecla Windows (envía `0x00` a la BIOS).

---

## 5. Ciclo de Vida del Dispositivo de Plataforma

### A. Inicialización (`hp_rgb_lighting_init`)
Cuando se carga el módulo (mediante `insmod` o `modprobe`):
1. Comprueba si el GUID de la BIOS de HP WMI está presente en el sistema con `wmi_has_guid`. Si no se detecta, se cancela con `-ENODEV` (evita la carga en hardware no compatible).
2. Registra un dispositivo virtual de plataforma llamado `"hp-rgb-lighting"` (`platform_device_register_simple`).
3. Crea y vincula los archivos de atributos sysfs (`zone0-7`, `brightness`, `win_lock`) al dispositivo utilizando `sysfs_create_groups`.

### B. Finalización (`hp_rgb_lighting_exit`)
Cuando se retira el módulo (mediante `rmmod`):
1. Elimina de forma segura los archivos virtuales de sysfs (`sysfs_remove_groups`).
2. Cancela el registro del dispositivo de plataforma (`platform_device_unregister`), liberando los recursos asignados del sistema.

---

## 6. Guía de Compilación, Instalación y Pruebas

### Archivo `Makefile` de Ejemplo
Cree un archivo llamado `Makefile` en el mismo directorio del archivo fuente con el siguiente contenido:

```makefile
obj-m += hp-rgb-lighting.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
```

### Instrucciones de Compilación y Carga
Ejecute los siguientes comandos en la terminal para compilar e insertar el módulo:

```bash
# 1. Compila el controlador kernel (.ko)
make

# 2. Carga el módulo compilado en el núcleo de Linux
sudo insmod hp-rgb-lighting.ko

# 3. Comprueba el registro del núcleo para verificar la carga exitosa
dmesg | grep hp-rgb-lighting
```

### Ejemplos de Comandos de Interacción

```bash
# Verifica los archivos de atributos generados en sysfs
ls -lh /sys/devices/platform/hp-rgb-lighting/

# Enciende la iluminación del teclado
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness

# Configura la Zona 0 en color Rojo
echo "FF0000" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone0

# Configura la Zona 1 en color Verde
echo "00FF00" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone1

# Activa el bloqueo de la tecla Windows (Win Lock)
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock

# Lee el color RGB hexadecimal actual configurado en la Zona 0
cat /sys/devices/platform/hp-rgb-lighting/zone0
```
