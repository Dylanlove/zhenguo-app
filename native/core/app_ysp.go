package core

import (
	"duanjuapp/native/ysp"
	"path/filepath"
)

func (engine *nativeEngine) nativeYSP(input nativeInput) (any, error) {
	engine.yspMu.Lock()
	service := engine.ysp
	if service == nil {
		var err error
		service, err = ysp.New(filepath.Join(engine.directory, "ysp-live"))
		if err != nil {
			engine.yspMu.Unlock()
			return nil, err
		}
		engine.ysp = service
	}
	engine.yspMu.Unlock()
	return service.Command(input.Command, input.YSP)
}
