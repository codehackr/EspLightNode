SDK:=/home/frans-willem/esp8266/SDK/esp_iot_sdk_v1.3.0
PORT:=/dev/ttyUSB0

OBJ_DIR:=objs
SRC_DIR:=user
OUTPUT_DIR:=firmware
RELEASE_DIR:=release


# Object files
OBJS:= cppcompat main wifisetup \
	CTimer \
	output_protocols/output output_protocols/COutput \
	output_protocols/ISPIInterface \
	output_protocols/CSPIBitbang \
	output_protocols/CSPIHardware \
	output_protocols/CWS2801Output \
	output_protocols/C3WireOutput \
	output_protocols/C3WireEncoder \
	output_protocols/CColorCorrector \
	output_protocols/CLimiter \
	input_protocols/tpm2net \
	input_protocols/artnet \
	config/config config/IConfigRunner config/CConfigHtmlGenerator config/CConfigPostHandler \
	config/CConfigWriter config/CConfigReader config/CConfigSection config/CConfigLoader \
	httpd/CTcpServer httpd/CTcpSocket \
	httpd/CHttpServer httpd/CHttpRequest \
	debug/CDebugServer \
	helpers


# Tool paths
TOOLCHAIN_PREFIX:=xtensa-lx106-elf-
CC:=$(TOOLCHAIN_PREFIX)gcc
CXX:=$(TOOLCHAIN_PREFIX)g++
LD:=$(TOOLCHAIN_PREFIX)ld
OBJDUMP:=$(TOOLCHAIN_PREFIX)objdump
OBJCOPY:=$(TOOLCHAIN_PREFIX)objcopy
STRIP:=$(TOOLCHAIN_PREFIX)strip
ESPTOOL:=esptool.py

# EspTool information, symbols needed, and firmware offsets generated
KEEPSYMS:=_text_start _data_start _rodata_start _irom0_text_start
FW_OFFSETS:=0x00000 0x40000

DEFINES:=-DENABLE_TPM2NET -DENABLE_ARTNET -DENABLE_WS2812
CXXFLAGS:=-Os -ggdb -std=c++0x -Wpointer-arith -Wundef -Wall -Wl,-EL -fno-inline-functions \
	-nostdlib -mlongcalls -mtext-section-literals -Wno-address \
	-I./include/ -I./$(SRC_DIR) -I$(SDK)/include \
	-fno-exceptions -fno-rtti -fno-inline-functions \
	-fdata-sections -ffunction-sections
CXXLDFLAGS:= -nostdlib -Wl,--no-check-sections \
	-Wl,-EL -Wl,-relocatable -Wl,--gc-sections \
	--entry user_init

# Library directories
LIBDIRS:=$(SDK)/lib
# Libraries that should be moved to the bigger flash section
LIBS_FIXUP:= stdc++ m
# Libraries that should stay at the smaller flash section
# Double libraries could keep some parts in big flash, and some parts on smaller flash.
LIBS_NOFIXUP:= c gcc main phy pp net80211 wpa lwip
# Linker script, adjust if you want to target a bigger flash chip
LDSCRIPT:=$(SDK)/ld/eagle.app.v6.ld

all: $(FW_OFFSETS:%=$(OUTPUT_DIR)/%.bin)

# Compilation of cpp files to .o files (object, compiled) and .d (dependency, used by Makefile)
-include $(OBJS:%=$(OBJ_DIR)/%.d)
$(OBJ_DIR)/%.o: $(SRC_DIR)/%.cpp
	mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -MM $< -MT $@ > $(@:%.o=%.d)
	$(CXX) $(CXXFLAGS) -c $< -o $@

# Stage 1 linking
# Everything that should be moved to the big flash area should be linked in at this point.
# Furthermore --gc-sections throws away all unreferenced sections
# And -fdata-sections and -ffunction-sections will make sure each function is in a seperate section.
# Ideally libc, libgcc, and libstdc++ should be compiled with those flags too for the biggest space savings.
$(OBJ_DIR)/firmware_stage1.elf: $(OBJS:%=$(OBJ_DIR)/%.o) $(OBJSXX:%=$(OBJ_DIR)/%.o)
	$(CXX) -o $@ $(CXXLDFLAGS) $(addprefix -L,$LIBDIRS) -Wl,--start-group $^ $(addprefix -l,$(LIBS_FIXUP)) -Wl,--end-group

# Find all sections starting with .text (either .text, or a function-specific section starting with .text)
$(OBJ_DIR)/function-sections.txt: $(OBJ_DIR)/firmware_stage1.elf
	$(OBJDUMP) -h $^ | grep "^\W*[[:digit:]]\+\W\+\.text" | awk '{print $$2}' > $@

# Same as above, for literals
$(OBJ_DIR)/literal-sections.txt: $(OBJ_DIR)/firmware_stage1.elf
	$(OBJDUMP) -h $^ | grep "^\W*[[:digit:]]\+\W\+\.literal" | awk '{print $$2}' > $@

# Create a list of all sections that should be renamed to .irom0.text (the big flash section)
$(OBJ_DIR)/rename-sections.txt: $(OBJ_DIR)/function-sections.txt $(OBJ_DIR)/literal-sections.txt
	cat $^ | awk '{print "--rename-section " $$0 "=.irom0.text"}' > $@

# Apply the mass section renaming.
$(OBJ_DIR)/firmware_stage2.elf: $(OBJ_DIR)/firmware_stage1.elf $(OBJ_DIR)/rename-sections.txt static-rename-sections.txt
	$(OBJCOPY) @$(word 2, $^) @$(word 3, $^) $< $@

# Link in the other libraries
$(OBJ_DIR)/firmware_stage3.elf: $(OBJ_DIR)/firmware_stage2.elf
	$(CXX) -o $@ -nostdlib $(addprefix -L,$(LIBDIRS)) -Wl,--start-group $(addprefix -l,$(LIBS_NOFIXUP)) $^ -Wl,--end-group -Wl,-T$(LDSCRIPT) -Wl,--gc-sections

# Strip out all symbols not used by ESPTOOL, as some undefined symbols left may confuse it.
$(OBJ_DIR)/firmware_stage4.elf: $(OBJ_DIR)/firmware_stage3.elf
	cp $^ $@
	$(STRIP) -s $(addprefix -K,$(KEEPSYMS)) $@

# Turn .elf file into .bin files ready for flashing
$(FW_OFFSETS:%=$(OUTPUT_DIR)/%.bin): $(OBJ_DIR)/firmware_stage4.elf
	@mkdir -p $(OUTPUT_DIR)
	$(ESPTOOL) elf2image --output $(OUTPUT_DIR)/ $^

# Flash!
flash: $(FW_OFFSETS:%=$(OUTPUT_DIR)/%.bin)
	$(ESPTOOL) --port $(PORT) --baud 460800 write_flash $(foreach x,$(FW_OFFSETS),$(x) $(OUTPUT_DIR)/$(x).bin)

$(OUTPUT_DIR)/blank.bin:
	@mkdir -p $(OUTPUT_DIR)
	tr '\0' '\377' < /dev/zero | dd of=$@ bs=4096 count=1

clearconfig: $(OUTPUT_DIR)/blank.bin $(FW_OFFSETS:%=$(OUTPUT_DIR)/%.bin)
	# Write all firmware, as writing just a blank sector also erases the one after it somehow.
	$(ESPTOOL) --port $(PORT) --baud 460800 write_flash `echo $$((63 * 4096))` $< $(foreach x,$(FW_OFFSETS),$(x) $(OUTPUT_DIR)/$(x).bin)

clean:
	rm -rf $(OBJ_DIR)
	rm -rf $(OUTPUT_DIR)
	rm -rf $(RELEASE_DIR)

.PHONY: release
release: $(FW_OFFSETS:%=$(OUTPUT_DIR)/%.bin) $(OUTPUT_DIR)/blank.bin LICENSE distri/README.txt
	$(eval $@_TMP := $(shell mktemp -d))
	$(eval $@_TARGET := EspLightNode-$(shell git describe --dirty)-$(shell date +%F).zip)
	mkdir $($@_TMP)/firmware
	mkdir $($@_TMP)/documentation
	cp LICENSE $($@_TMP)
	cp distri/README.txt $($@_TMP)
	cp $(FW_OFFSETS:%=$(OUTPUT_DIR)/%.bin) $($@_TMP)/firmware
	cp $(OUTPUT_DIR)/blank.bin $($@_TMP)/firmware
	git describe --dirty > $($@_TMP)/VERSION.txt
	@mkdir -p $(RELEASE_DIR)
	rm -f $(RELEASE_DIR)/$($@_TARGET)
	cd $($@_TMP); zip -r "$(abspath $(RELEASE_DIR))/$($@_TARGET)" .
	rm -r $($@_TMP)
