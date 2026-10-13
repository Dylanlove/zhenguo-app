package ysp

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

var signingCache = wazero.NewCompilationCache()

func leb(raw []byte, offset *int) (uint32, error) {
	var value uint32
	for shift := uint(0); shift < 35; shift += 7 {
		if *offset >= len(raw) {
			return 0, errors.New("WASM 数据不完整")
		}
		part := raw[*offset]
		*offset++
		value |= uint32(part&127) << shift
		if part&128 == 0 {
			return value, nil
		}
	}
	return 0, errors.New("WASM 整数无效")
}
func putLeb(value uint32) []byte {
	result := []byte{}
	for {
		part := byte(value & 127)
		value >>= 7
		if value != 0 {
			part |= 128
		}
		result = append(result, part)
		if value == 0 {
			return result
		}
	}
}
func wasmName(raw []byte, offset *int) error {
	size, err := leb(raw, offset)
	if err != nil {
		return err
	}
	if int(size) > len(raw)-*offset {
		return errors.New("WASM 名称无效")
	}
	*offset += int(size)
	return nil
}
func wasmLimits(raw []byte, offset *int) error {
	flags, err := leb(raw, offset)
	if err != nil {
		return err
	}
	if _, err = leb(raw, offset); err != nil {
		return err
	}
	if flags&1 != 0 {
		_, err = leb(raw, offset)
	}
	return err
}

type wasmSection struct {
	id  byte
	raw []byte
}

func localTicket(raw []byte) ([]byte, error) {
	if len(raw) < 8 {
		return nil, errors.New("WASM 票据模块无效")
	}
	sections := []wasmSection{}
	var table, memory []byte
	offset := 8
	for offset < len(raw) {
		id := raw[offset]
		offset++
		size, err := leb(raw, &offset)
		if err != nil || int(size) > len(raw)-offset {
			return nil, errors.New("WASM 节区无效")
		}
		data := raw[offset : offset+int(size)]
		offset += int(size)
		if id == 2 {
			at := 0
			count, err := leb(data, &at)
			if err != nil {
				return nil, err
			}
			kept := []byte{}
			retained := uint32(0)
			for index := uint32(0); index < count; index++ {
				start := at
				if err = wasmName(data, &at); err != nil {
					return nil, err
				}
				if err = wasmName(data, &at); err != nil {
					return nil, err
				}
				if at >= len(data) {
					return nil, errors.New("WASM 导入无效")
				}
				kind := data[at]
				at++
				descriptor := at
				switch kind {
				case 0:
					_, err = leb(data, &at)
				case 1:
					at++
					err = wasmLimits(data, &at)
					table = append([]byte(nil), data[descriptor:at]...)
				case 2:
					err = wasmLimits(data, &at)
					memory = append([]byte(nil), data[descriptor:at]...)
				case 3:
					at += 2
				default:
					return nil, errors.New("WASM 导入类型不支持")
				}
				if err != nil || at > len(data) {
					return nil, errors.New("WASM 导入长度无效")
				}
				if kind != 1 && kind != 2 {
					kept = append(kept, data[start:at]...)
					retained++
				}
			}
			data = append(putLeb(retained), kept...)
		}
		sections = append(sections, wasmSection{id, data})
	}
	result := append([]byte(nil), raw[:8]...)
	appendSection := func(id byte, data []byte) {
		result = append(result, id)
		result = append(result, putLeb(uint32(len(data)))...)
		result = append(result, data...)
	}
	addedTable, addedMemory := false, false
	for _, section := range sections {
		if section.id != 0 {
			if section.id >= 4 && !addedTable && len(table) > 0 {
				if section.id == 4 {
					return nil, errors.New("WASM 票据表布局不支持")
				}
				appendSection(4, append([]byte{1}, table...))
				addedTable = true
			}
			if section.id >= 5 && !addedMemory && len(memory) > 0 {
				if section.id == 5 {
					return nil, errors.New("WASM 票据内存布局不支持")
				}
				appendSection(5, append([]byte{1}, memory...))
				addedMemory = true
			}
		}
		appendSection(section.id, section.raw)
	}
	if !addedMemory || !addedTable {
		return nil, errors.New("WASM 票据模块缺少内存或表")
	}
	return result, nil
}

func newSigningRuntime(ctx context.Context) wazero.Runtime {
	config := wazero.NewRuntimeConfigInterpreter().WithCompilationCache(signingCache).WithMemoryLimitPages(512).WithCloseOnContextDone(true)
	return wazero.NewRuntimeWithConfig(ctx, config)
}
func wasmCall(ctx context.Context, module api.Module, name string, args ...uint64) ([]uint64, error) {
	function := module.ExportedFunction(name)
	if function == nil {
		return nil, fmt.Errorf("央视频签名模块缺少 %s", name)
	}
	return function.Call(ctx, args...)
}

func keygen(ctx context.Context, state map[string]string, export string) (string, error) {
	runtime := newSigningRuntime(ctx)
	defer runtime.Close(ctx)
	raw, err := bundled.ReadFile("assets/keygen.wasm")
	if err != nil {
		return "", err
	}
	compiled, err := runtime.CompileModule(ctx, raw)
	if err != nil {
		return "", err
	}
	heap := make([]*string, 132)
	for index, value := range []string{"null", "true", "false"} {
		copy := value
		heap[index+129] = &copy
	}
	builder := runtime.NewHostModuleBuilder("wbg")
	for _, definition := range compiled.ImportedFunctions() {
		_, name, _ := definition.Import()
		function := api.GoModuleFunc(func(ctx context.Context, module api.Module, stack []uint64) {
			switch name {
			case "__wbg_get_9c1840f7ecd81363":
				raw, ok := module.Memory().Read(uint32(stack[0]), uint32(stack[1]))
				if !ok {
					panic("央视频签名读取越界")
				}
				value := state[string(raw)]
				heap = append(heap, &value)
				stack[0] = uint64(len(heap) - 1)
			case "__wbindgen_string_get":
				out, index := uint32(stack[0]), int(stack[1])
				pointer, length := uint32(0), uint32(0)
				if index < len(heap) && heap[index] != nil {
					value := []byte(*heap[index])
					result, err := wasmCall(ctx, module, "__wbindgen_malloc", uint64(len(value)), 1)
					if err != nil {
						panic(err)
					}
					pointer = uint32(result[0])
					length = uint32(len(value))
					if !module.Memory().Write(pointer, value) {
						panic("央视频签名写入越界")
					}
				}
				module.Memory().WriteUint32Le(out, pointer)
				module.Memory().WriteUint32Le(out+4, length)
			case "__wbindgen_object_drop_ref":
				index := int(stack[0])
				if index >= 132 && index < len(heap) {
					heap[index] = nil
				}
			default:
				panic("央视频签名导入不支持")
			}
		})
		builder.NewFunctionBuilder().WithGoModuleFunction(function, definition.ParamTypes(), definition.ResultTypes()).Export(name)
	}
	if _, err = builder.Instantiate(ctx); err != nil {
		return "", err
	}
	module, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName("ysp-keygen").WithStartFunctions())
	if err != nil {
		return "", err
	}
	pointers, err := wasmCall(ctx, module, "__wbindgen_add_to_stack_pointer", 0xfffffff0)
	if err != nil {
		return "", err
	}
	out := uint32(pointers[0])
	if _, err = wasmCall(ctx, module, export, uint64(out)); err != nil {
		return "", err
	}
	pointer, ok := module.Memory().ReadUint32Le(out)
	if !ok {
		return "", errors.New("央视频签名输出无效")
	}
	size, ok := module.Memory().ReadUint32Le(out + 4)
	if !ok || size > 4096 {
		return "", errors.New("央视频签名长度无效")
	}
	raw, ok = module.Memory().Read(pointer, size)
	if !ok {
		return "", errors.New("央视频签名输出越界")
	}
	value := string(raw)
	if _, err = wasmCall(ctx, module, "__wbindgen_add_to_stack_pointer", 16); err != nil {
		return "", err
	}
	if pointer > 0 {
		if _, err = wasmCall(ctx, module, "__wbindgen_free", uint64(pointer), uint64(size), 1); err != nil {
			return "", err
		}
	}
	return value, nil
}

func ticket(ctx context.Context, pid, stamp, cnlid, guid string) (string, error) {
	raw, err := bundled.ReadFile("assets/ticket.wasm")
	if err != nil {
		return "", err
	}
	raw, err = localTicket(raw)
	if err != nil {
		return "", err
	}
	runtime := newSigningRuntime(ctx)
	defer runtime.Close(ctx)
	compiled, err := runtime.CompileModule(ctx, raw)
	if err != nil {
		return "", err
	}
	builder := runtime.NewHostModuleBuilder("a")
	for _, definition := range compiled.ImportedFunctions() {
		_, name, _ := definition.Import()
		function := api.GoModuleFunc(func(ctx context.Context, module api.Module, stack []uint64) {
			result := uint64(0)
			switch name {
			case "d":
				result = uint64(time.Now().Unix())
				if stack[0] != 0 {
					module.Memory().WriteUint32Le(uint32(stack[0]), uint32(result))
				}
			case "e":
				result = 42
			case "i", "j":
				now := time.Now()
				pointer := uint32(stack[0])
				if name == "j" {
					pointer = uint32(stack[1])
				}
				module.Memory().WriteUint32Le(pointer, uint32(now.Unix()))
				fraction := now.Nanosecond()
				if name == "i" {
					fraction /= 1000
				}
				module.Memory().WriteUint32Le(pointer+4, uint32(fraction))
			case "o", "q":
				result = 0xffffffff
			case "s":
				module.Memory().WriteUint32Le(uint32(stack[4]), 0)
				module.Memory().WriteUint32Le(uint32(stack[4])+4, 0)
			case "t":
				destination, source, size := uint32(stack[0]), uint32(stack[1]), uint32(stack[2])
				src, ok := module.Memory().Read(source, size)
				if !ok {
					panic("央视频票据读取越界")
				}
				dst, ok := module.Memory().Read(destination, size)
				if !ok {
					panic("央视频票据写入越界")
				}
				copy(dst, src)
				result = uint64(destination)
			case "v":
				module.Memory().Write(uint32(stack[1]), []byte{4})
			case "x":
				module.Memory().WriteUint32Le(uint32(stack[0]), 0)
				module.Memory().WriteUint32Le(uint32(stack[1]), 0)
			case "O":
				result = 1
			}
			if len(definition.ResultTypes()) > 0 {
				stack[0] = result
			}
		})
		builder.NewFunctionBuilder().WithGoModuleFunction(function, definition.ParamTypes(), definition.ResultTypes()).Export(name)
	}
	if _, err = builder.Instantiate(ctx); err != nil {
		return "", err
	}
	module, err := runtime.InstantiateModule(ctx, compiled, wazero.NewModuleConfig().WithName("ysp-ticket").WithStartFunctions())
	if err != nil {
		return "", err
	}
	if _, err = wasmCall(ctx, module, "P"); err != nil {
		return "", err
	}
	allocate := func(value string) (uint64, error) {
		result, err := wasmCall(ctx, module, "R", uint64(len(value)+1))
		if err != nil {
			return 0, err
		}
		if !module.Memory().Write(uint32(result[0]), append([]byte(value), 0)) {
			return 0, errors.New("央视频票据写入失败")
		}
		return result[0], nil
	}
	args := make([]uint64, 0, 7)
	for _, value := range []string{pid, stamp, cnlid, guid, "519748109", "V1.0.0"} {
		pointer, err := allocate(value)
		if err != nil {
			return "", err
		}
		args = append(args, pointer)
	}
	size := len(pid) + len(stamp) + len(guid) + len("519748109") + 14
	output, err := wasmCall(ctx, module, "R", uint64(size))
	if err != nil {
		return "", err
	}
	args = append(args, output[0])
	if _, err = wasmCall(ctx, module, "T", args...); err != nil {
		return "", err
	}
	raw, ok := module.Memory().Read(uint32(output[0]), uint32(size))
	if !ok {
		return "", errors.New("央视频票据输出无效")
	}
	return hex.EncodeToString(raw), nil
}

func signingState(guid, token, input, stamp string) map[string]string {
	return map[string]string{"cctvh5openapi.state.guid": guid, "cctvh5openapi.state.yspappid": "519748109", "cctvh5openapi.state.version": "v1", "window.location.host": "www.yangshipin.cn", "window.location.protocol": "https:", "cctvh5openapi.state.token": token, "cctvh5openapi.state.input": input, "cctvh5openapi.state.ts": stamp}
}
