project(xrGameSpy)
set(XGS_SRC_FILES)

# Files import
file(GLOB XGS_SOURCE_GS_FILES
    "DistributionFunc.cpp"
    "gamespy/common/gsAvailable.c"
    "gamespy/common/gsCore.c"
    "gamespy/common/gsCrypt.c"
    "gamespy/common/gsLargeInt.c"
    "gamespy/common/gsRC4.c"
    "gamespy/common/gsSHA1.c"
    "gamespy/common/gsSoap.c"
    "gamespy/common/gsSSL.c"
    "gamespy/common/gsStringUtil.c"
    "gamespy/common/gsUdpEngine.c"
    "gamespy/common/gsXML.c"
    "gamespy/darray.c"
    "gamespy/gcdkey/gcdkeyc.c"
    "gamespy/gcdkey/gcdkeys.c"
    "gamespy/ghttp/ghttpBuffer.c"
    "gamespy/ghttp/ghttpCallbacks.c"
    "gamespy/ghttp/ghttpCommon.c"
    "gamespy/ghttp/ghttpConnection.c"
    "gamespy/ghttp/ghttpEncryption.c"
    "gamespy/ghttp/ghttpMain.c"
    "gamespy/ghttp/ghttpPost.c"
    "gamespy/ghttp/ghttpProcess.c"
    "gamespy/GP/gp.c"
    "gamespy/GP/gpi.c"
    "gamespy/GP/gpiBuddy.c"
    "gamespy/GP/gpiBuffer.c"
    "gamespy/GP/gpiCallback.c"
    "gamespy/GP/gpiConnect.c"
    "gamespy/GP/gpiInfo.c"
    "gamespy/GP/gpiKeys.c"
    "gamespy/GP/gpiOperation.c"
    "gamespy/GP/gpiPeer.c"
    "gamespy/GP/gpiProfile.c"
    "gamespy/GP/gpiPS3.c"
    "gamespy/GP/gpiSearch.c"
    "gamespy/GP/gpiTransfer.c"
    "gamespy/GP/gpiUnique.c"
    "gamespy/GP/gpiUtility.c"
    "gamespy/gstats/gbucket.c"
    "gamespy/gstats/gstats.c"
    "gamespy/gt2/gt2Auth.c"
    "gamespy/gt2/gt2Buffer.c"
    "gamespy/gt2/gt2Callback.c"
    "gamespy/gt2/gt2Connection.c"
    "gamespy/gt2/gt2Encode.c"
    "gamespy/gt2/gt2Filter.c"
    "gamespy/gt2/gt2Main.c"
    "gamespy/gt2/gt2Message.c"
    "gamespy/gt2/gt2Socket.c"
    "gamespy/gt2/gt2Utility.c"
    "gamespy/hashtable.c"
    "gamespy/md5c.c"
    "gamespy/natneg/NATify.c"
    "gamespy/natneg/natneg.c"
    "gamespy/nonport.c"
    "gamespy/qr2/qr2.c"
    "gamespy/qr2/qr2regkeys.c"
    "gamespy/sake/sakeMain.c"
    "gamespy/sake/sakeRequest.c"
    "gamespy/sake/sakeRequestMisc.c"
    "gamespy/sake/sakeRequestModify.c"
    "gamespy/sake/sakeRequestRead.c"
    "gamespy/sc/sciInterface.c"
    "gamespy/sc/sciMain.c"
    "gamespy/sc/sciReport.c"
    "gamespy/sc/sciSerialize.c"
    "gamespy/sc/sciWebServices.c"
    "gamespy/serverbrowsing/sb_crypt.c"
    "gamespy/serverbrowsing/sb_queryengine.c"
    "gamespy/serverbrowsing/sb_server.c"
    "gamespy/serverbrowsing/sb_serverbrowsing.c"
    "gamespy/serverbrowsing/sb_serverlist.c"
    "gamespy/webservices/AuthService.c"
)

file(GLOB XGS_SOURCE_GSC_FILES
    "xrGameSpy.cpp"
    "xrGameSpy_ATLAS.cpp"
    "xrGameSpy_Available.cpp"
    "xrGameSpy_CDKey.cpp"
    "xrGameSpy_Core.cpp"
    "xrGameSpy_GP.cpp"
    "xrGameSpy_HTTP.cpp"
    "xrGameSpy_QR2.cpp"
    "xrGameSpy_SAKE.cpp"
    "xrGameSpy_ServerBrowser.cpp"
)

# Source groups
source_group("gsc" FILES ${XGS_SOURCE_GSC_FILES})
source_group("gamespy" FILES ${XGS_SOURCE_GS_FILES})

# Apply list
list(APPEND XGS_SRC_FILES ${XGS_SOURCE_GS_FILES})
list(APPEND XGS_SRC_FILES ${XGS_SOURCE_GSC_FILES})

# Remove unused files
#list(FILTER XGS_SRC_FILES EXCLUDE REGEX "GameSpy_Patching.cpp$")

# xrGameSpy project
add_library(xrGameSpy SHARED ${XGS_SRC_FILES})
set_target_properties(xrGameSpy PROPERTIES DISABLE_PRECOMPILE_HEADERS ON)

# Include directories
target_include_directories(xrGameSpy PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_include_directories(xrGameSpy PUBLIC "${IXRAY_SDK_INC}")

# Project defines
target_compile_definitions(xrGameSpy PRIVATE XRGAMESPY_EXPORTS)
target_compile_definitions(xrGameSpy PRIVATE _USRDLL)

# Linker list
target_link_libraries(xrGameSpy PUBLIC xrCore)