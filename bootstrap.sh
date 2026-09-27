#!/bin/sh
#
# Build glm_freebsd_package by bootstrapping with this shell script.
#
# References:
# * https://lastsummer.de/creating-custom-packages-on-freebsd/
# * https://gist.github.com/matthewp/431e0c89d9492ea5601ce9c01a5676af

# ------------------------------------------------------------------------
# INPUTS
# ------------------------------------------------------------------------
STAGE_DIR=$1
OUTPUT_DIR=$2
VERSION=$3
BIN_DIR=$4
PREFIX_DIR=$5
TEMPLATES_DIR=$6

PKG_NAME="glm_freebsd_package"
STAGE_DIR="${STAGE_DIR:=./staging}"
OUTPUT_DIR="${OUTPUT_DIR:=./packages}"
VERSION="${VERSION:=1.0.0}"
STAGING_DIR="${STAGE_DIR}/staging"
METADATA_DIR="${STAGE_DIR}/metadata"
FILES_DIR="${STAGE_DIR}/files"
INSTALL_DIR="${PREFIX_DIR}/bin"

mkdir -p ${METADATA_DIR}
mkdir -p ${FILES_DIR}
mkdir -p ${OUTPUT_DIR}

# ------------------------------------------------------------------------
# debug
# ------------------------------------------------------------------------

# echo "STAGE_DIR=${STAGE_DIR}"
# echo "OUTPUT_DIR=${OUTPUT_DIR}"
# echo "VERSION=${VERSION}"
# echo "BIN_DIR=${BIN_DIR}"
# echo "PREFIX_DIR=${PREFIX_DIR}"
# echo "TEMPLATES_DIR=${TEMPLATES_DIR}"
# echo "PKG_NAME=${PKG_NAME}"
# echo "STAGING_DIR=${STAGING_DIR}"
# echo "METADATA_DIR=${METADATA_DIR}"
# echo "FILES_DIR=${FILES_DIR}"
# echo "INSTALL_DIR=${INSTALL_DIR}"

# ------------------------------------------------------------------------
# PRE AND POST INSTALL FILES
# ------------------------------------------------------------------------

cat >> ${METADATA_DIR}/+PRE_DEINSTALL <<EOF
#! /bin/sh
EOF

cat >> ${METADATA_DIR}/+POST_INSTALL <<EOF
#! /bin/sh
EOF

# ------------------------------------------------------------------------
# MANIFEST FILE : CREATE
# ------------------------------------------------------------------------
cat >> ${METADATA_DIR}/+MANIFEST <<EOF
name: glm_freebsd_package
version: "$VERSION"
origin: gleam/tools
comment: "Package gleam applications as FreeBSD services."
desc: "Package gleam applications as FreeBSD services."
maintainer: toddg@zwrob.com
www: git@github.com:ToddG/glm_freebsd_package.git
prefix: ${PREFIX_DIR}
EOF

# ------------------------------------------------------------------------
# MANIFEST FILE : APPEND DEPS
# ------------------------------------------------------------------------
cat >> ${METADATA_DIR}/+MANIFEST <<EOF
deps: {
   erlang: {origin: "lang/erlang", version: "28"},
   erlang-runtime28: {origin: "lang/erlang-runtime28", version: "28"},
   gleam: {origin: "lang/gleam", version: "1"},
}
EOF
# ------------------------------------------------------------------------
# PLIST : APPEND FILES
# ------------------------------------------------------------------------
touch ${METADATA_DIR}/plist
# cp escript
mkdir -p ${FILES_DIR}${INSTALL_DIR}
cp ${BIN_DIR}/${PKG_NAME} ${FILES_DIR}${INSTALL_DIR}
# cp templates
mkdir -p ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/
cp priv/templates/freebsd/rc.template ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/rc.template
cp priv/templates/freebsd/+PRE_DEINSTALL.template ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/+PRE_DEINSTALL.template
cp priv/templates/freebsd/rc_conf.template ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/rc_conf.template
cp priv/templates/freebsd/+DISPLAY.template ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/+DISPLAY.template
cp priv/templates/freebsd/+DESC.template ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/+DESC.template
cp priv/templates/freebsd/+POST_INSTALL.template ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/+POST_INSTALL.template
cp priv/templates/freebsd/+MANIFEST.template ${FILES_DIR}${TEMPLATES_DIR}/templates/freebsd/+MANIFEST.template
# update plist
echo ${INSTALL_DIR}/${PKG_NAME} >> ${METADATA_DIR}/plist
echo ${TEMPLATES_DIR}/templates/freebsd/rc.template >> ${METADATA_DIR}/plist
echo ${TEMPLATES_DIR}/templates/freebsd/+PRE_DEINSTALL.template >> ${METADATA_DIR}/plist
echo ${TEMPLATES_DIR}/templates/freebsd/rc_conf.template >> ${METADATA_DIR}/plist
echo ${TEMPLATES_DIR}/templates/freebsd/+DISPLAY.template >> ${METADATA_DIR}/plist
echo ${TEMPLATES_DIR}/templates/freebsd/+DESC.template >> ${METADATA_DIR}/plist
echo ${TEMPLATES_DIR}/templates/freebsd/+POST_INSTALL.template >> ${METADATA_DIR}/plist
echo ${TEMPLATES_DIR}/templates/freebsd/+MANIFEST.template >> ${METADATA_DIR}/plist
cat ${METADATA_DIR}/plist

# ------------------------------------------------------------------------
# PKG CREATE
# ------------------------------------------------------------------------
pkg create -m ${METADATA_DIR} -r ${FILES_DIR} -p ${METADATA_DIR}/plist -o ${OUTPUT_DIR}
ls ${OUTPUT_DIR}
