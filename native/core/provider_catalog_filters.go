package core

import (
	"errors"
	"net/url"
	"strings"
)

type nativeCategoryFilter struct {
	Key          string           `json:"key"`
	Name         string           `json:"name"`
	Default      string           `json:"default"`
	Values       []nativeCategory `json:"values"`
	ParentKey    string           `json:"parentKey,omitempty"`
	ParentValues []string         `json:"parentValues,omitempty"`
}

func providerCategorySelection(categories []nativeCategory, selection string) (nativeCategory, url.Values, error) {
	id, query, _ := strings.Cut(selection, "?")
	values, err := url.ParseQuery(query)
	if err != nil {
		return nativeCategory{}, nil, errors.New("站源分类筛选无效")
	}
	for _, category := range categories {
		if category.ID != id {
			continue
		}
		selected := url.Values{}
		for _, filter := range category.Filters {
			if filter.ParentKey != "" {
				active := false
				for _, parent := range filter.ParentValues {
					active = active || selected.Get(filter.ParentKey) == parent
				}
				if !active {
					continue
				}
			}
			value := filter.Default
			if raw, found := values[filter.Key]; found {
				if len(raw) != 1 {
					return nativeCategory{}, nil, errors.New("站源筛选参数重复")
				}
				value = raw[0]
			}
			valid := false
			for _, option := range filter.Values {
				valid = valid || value == option.ID
			}
			if !valid {
				return nativeCategory{}, nil, errors.New("站源筛选选项无效")
			}
			selected.Set(filter.Key, value)
		}
		for key := range values {
			if _, found := selected[key]; !found {
				return nativeCategory{}, nil, errors.New("站源不支持此筛选参数")
			}
		}
		return category, selected, nil
	}
	return nativeCategory{}, nil, errors.New("站源分类无效")
}

func providerCategoryValid(categories []nativeCategory, selection string) bool {
	_, _, err := providerCategorySelection(categories, selection)
	return err == nil
}
