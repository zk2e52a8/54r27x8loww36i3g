#!/bin/bash

# Este script recopila identificadores de miniaturas de fichas en zonatmo.com según sus etiquetas, para generar un filtro de bloqueo compatible con uBlock

# NOTE Sobre la obtención de la URL:
# Se usa "zonatmo.com/library" (BIBLIOTECA) para listar entradas filtrando sus tags y flags
# Permanecer en la página 1 genera un formato de URL no deseado; es necesario avanzar en la lista
# Debe eliminarse el número final, que corresponde a la página actual
# Es importante ordenar por "Creación" para evitar detectar duplicados prematuramente

URLs=(
	# Flags:Seinen Tags:+Ecchi
	"https://zonatmo.com/library?order_item=creation&order_dir=desc&demography=seinen&filter_by=title&genders%5B0%5D=6&_pg=1&page="
	# Flags:Shounen Tags:+Ecchi
	"https://zonatmo.com/library?order_item=creation&order_dir=desc&demography=shounen&filter_by=title&genders%5B0%5D=6&_pg=1&page="
	# Flags:Seinen,Erótico
	"https://zonatmo.com/library?order_item=creation&order_dir=desc&demography=seinen&filter_by=title&erotic=true&_pg=1&page="
	# Flags:Shounen,Erótico
	"https://zonatmo.com/library?order_item=creation&order_dir=desc&demography=shounen&filter_by=title&erotic=true&_pg=1&page="
	# Tags:+Ecchi,+Vida escolar
	"https://zonatmo.com/library?order_item=creation&order_dir=desc&filter_by=title&genders%5B0%5D=6&genders%5B1%5D=26&_pg=1&page="
	# Tags:+Girls Love
	"https://zonatmo.com/library?order_item=creation&order_dir=desc&filter_by=title&genders%5B0%5D=17&_pg=1&page="
	# Flags:Kodomo
	"https://zonatmo.com/library?order_item=creation&order_dir=desc&demography=kodomo&filter_by=title&_pg=1&page="
)

# Carpeta en la que se guardará el filtro
carpeta_filtro="$GITHUB_WORKSPACE"

# Carpeta para almacenar los archivos (uno por url) de identificadores de miniaturas, para limitar los reescaneos
carpeta_ids="$GITHUB_WORKSPACE/identificadores_TMO/"

# Archivo en el que se almacena la fecha del último reinicio de los filtros
archivo_timestamp="$carpeta_ids/RESET.timestamp"

# Frecuencia para el reinicio de filtros, en días
# Deben reiniciarse regularmente, ya que las fichas antiguas pueden ser actualizadas
limite_reset=$((6 * 24 * 3600))

# Límite de intentos de descarga
tiempo_espera="120" # En segundos
max_intentos="30" # Lo que equivale a un total de una hora

#################### Fin de la configuración

fecha_actual=$(date +%s)

# Leer el timestamp anterior y calcular la diferencia de tiempo
ultimo_reset=$(cat "$archivo_timestamp")
diff_reset=$(($fecha_actual - ultimo_reset))

if [ ! -f "$archivo_timestamp" ]; then
	modo_reset="SI"
	echo "Archivo timestamp no encontrado, activando el modo reset"
elif [ "$diff_reset" -gt "$limite_reset" ]; then
	modo_reset="SI"
	echo "Se ha superado la fecha límite para el reinicio del filtro, activando el modo reset"
elif [[ "$1" == "RESET" ]]; then
	modo_reset="SI"
	echo "Se ha ejecutado el script con el argumento 'RESET', modo reset activado"
else
	modo_reset="NO"
	echo "Modo reset desactivado"
fi

# Crear las carpetas necesarias para evitar errores
mkdir -p "$carpeta_filtro" "$carpeta_ids"

# Archivo temporal para unificar identificadores de todas las URLs procesadas
ids_unificados=$(mktemp)

# Función para limpiar archivos temporales al finalizar, incluso en (la mayoría de) casos de error
limpiar_tmp() {
	rm -f "$ids_unificados" "$archivo_ids_temporal" "$ids_diff" "$base_filtro"
}
trap limpiar_tmp EXIT

intentos_descarga=0

#####

procesar_identificadores() {
	# Verificar si hay identificadores
	if [[ -z $nuevos_identificadores ]]; then
		if [[ $numero_pagina -eq 1 ]]; then
			echo "No hay resultados válidos en la página 1"
			echo "Puede que haya un error en la URL o que el patrón a procesar haya cambiado"
			echo "Abortando el script"
			exit 1
		else
			echo "No hay resultados válidos en la página $numero_pagina, se asume que se llegó al final"
			return 1
		fi
	fi

	# Si el script se ejecuta con "RESET", omitir la verificación de duplicados
	if [[ "$modo_reset" == "SI" ]]; then
		echo "$nuevos_identificadores" >> "$archivo_ids_temporal"
		return 0
	fi

	# Verificar si existen identificadores desconocidos entre los nuevos
	# NOTE Incluso si se reinicia cada vez, puede haber duplicados dentro de la misma url
	while IFS= read -r id; do
		if ! grep -q "^$id$" "$archivo_ids_temporal"; then
			echo "$nuevos_identificadores" >> "$archivo_ids_temporal"
			return 0
		fi
	done <<< "$nuevos_identificadores"

	# Todos los identificadores nuevos ya existen, pasar a la siguiente URL
	echo "La página $numero_pagina solo contiene identificadores conocidos"
	return 1
}

descargar_pagina() {
	while true; do
		# Descargar la página
		contenido_pagina=$(curl --silent --fail -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.1" "$url_completa")
		local salida_curl=$?

		if [ $salida_curl -eq 0 ] && [[ -n "$contenido_pagina" ]]; then
			echo "Página $numero_pagina descargada con éxito"
			break
		fi

		intentos_descarga=$((intentos_descarga + 1))

		# Verificar si se ha superado el máximo de intentos
		if [ $intentos_descarga -ge $max_intentos ]; then
			echo "Error al descargar desde el servidor en $max_intentos ocasiones"
			echo "Si esto ocurre al inicio, puede que haya un problema con el agente de usuario de curl"
			echo "Abortando el script"
			exit 1
		else
			echo "Intento fallido nº$intentos_descarga de descargar del servidor. No se pudo obtener la página $numero_pagina."
			echo "Salida de error: $salida_curl"
			sleep $tiempo_espera
		fi
	done
}

# Procesar cada URL
for url_base in "${URLs[@]}"; do
	numero_pagina=0

	# Convertir la url en un nombre de archivo para almacenar los identificadores, usando solo caracteres simples
	archivo_ids_original=$(echo "$carpeta_ids/$(echo "$url_base" | sed -e 's|https://||' -e 's|[^a-zA-Z0-9.]|-|g').txt")
	archivo_ids_temporal=$(mktemp)

	# Asegurarse de que el archivo de identificadores exista o crear uno vacío
	touch "$archivo_ids_original"

	# Copiar el archivo de identificadores actual al archivo temporal, siempre que no se ejecute con "RESET"
	if [[ "$modo_reset" == "NO" ]]; then
		cp "$archivo_ids_original" "$archivo_ids_temporal"
	fi

	echo; echo "Iniciando descargas para: $url_base"

	# Procesar todas las páginas de la URL base actual
	while true; do
		# Incrementar el número de página
		numero_pagina=$((numero_pagina + 1))

		# Construir la URL completa
		url_completa="${url_base}${numero_pagina}"

		# Pausa para evitar el bloqueo por scraping
		sleep 10

		# Descargar y verificar la descarga de la página
		descargar_pagina

		# Buscar y extraer los identificadores
		nuevos_identificadores=$(echo "$contenido_pagina" | grep --perl-regexp --only-matching '<div class="thumbnail book book-thumbnail-\K[0-9]{1,6}(?=">)' | tr ' ' '\n')

		# Procesar identificadores. Si la salida/return no es 0, terminar con la URL base
		if ! procesar_identificadores; then
			# Agregar los nuevos identificadores al archivo unificado
			cat "$archivo_ids_temporal" >> "$ids_unificados"

			# Identificar los cambios respecto al archivo de identificadores original y parchearlo
			ids_diff=$(mktemp)
			sort --unique -o "$archivo_ids_temporal" "$archivo_ids_temporal"
			diff -u "$archivo_ids_original" "$archivo_ids_temporal" > "$ids_diff"
			patch "$archivo_ids_original" < "$ids_diff"

			# Eliminar archivos temporales
			rm "$ids_diff"
			rm "$archivo_ids_temporal"
			break
		fi
	done
done

echo "Descargas completadas, procesando los datos..."

#####

# Ordenar el archivo temporal global y eliminar duplicados
sort --unique -o "$ids_unificados" "$ids_unificados"

# Formatear los identificadores para uBlock, añadiendo prefijos y sufijos específicos
base_filtro=$(mktemp)
sed 's|^|zonatmo.com##.book-thumbnail-|; s|$|.book.thumbnail|' "$ids_unificados" > "$base_filtro"

# Añadir la cabecera y guardar el filtro
{	echo "! Title: Filtros para TMO"
	echo "! Last modified: $(TZ="UTC" date +"%a, %d %b %Y %H:%M:%S %z")"
	echo "! Expires: 6 hours"
	echo
	cat "$base_filtro"
} > "$carpeta_filtro/filtro_ublock_TMO.txt"

# Actualizar el timestamp del archivo reset
if [ "$modo_reset" == "SI" ]; then
	echo "$fecha_actual" > "$archivo_timestamp"
fi

echo "Finalizado"
