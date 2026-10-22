package core

import (
	"crypto/md5"
	"encoding/hex"
	"fmt"
	"net/http"
	"testing"
	"time"
)

func TestHongguoSM3Reference(t *testing.T) {
	digest := hongguoSM3([]byte("abc"))
	if hex.EncodeToString(digest[:]) != "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0" {
		t.Fatal("SM3 differs from the reference digest")
	}
}

func TestHongguoMedusaHashReferenceBranches(t *testing.T) {
	body := md5.Sum([]byte(`{"mixed_video_id_map":{"1004":["800001"]}}`))
	samples := []struct{ query, expected string }{
		{"aid=8662&fixture=26", "e58ab6ac6699d74b56524ddcda8ad9b3dfda025c"},
		{"aid=8662&fixture=10", "0fc5a1bf16452a2c61590b83b0f12b4907b2d85b"},
		{"aid=8662&fixture=9", "51cd16169f57f6f21a1f08df9adcf7206e43cd37"},
		{"aid=8662&fixture=31", "d67a34965acbc561412eb3119d78e36a5770faa1"},
		{"aid=8662&fixture=20", "4cfcf412208f1f2d22c6b9ca1101341286b54834"},
		{"aid=8662&fixture=1", "2369c869d4a104a7f46f150cec4f79dfb7c8abd5"},
		{"aid=8662&fixture=6", "1f96a64c14e3c426118dccdb93868ff056b3d56a"},
		{"aid=8662&fixture=17", "6674cae9d092e2781bc725c09c0074d44c726e72"},
		{"aid=8662&fixture=13", "82049597b3a6e8379fadeee6e98b733a169b577a"},
		{"aid=8662&fixture=15", "5467ba4e414feefba14bed63c0645e0a052163a4"},
		{"aid=8662&fixture=2", "68e41346fff5dd4e3069082aea2ec270548299fc"},
		{"aid=8662&fixture=24", "d4920d212bb343ca00a68ad3c31db8862540fc0d"},
		{"aid=8662&fixture=4", "95bc12793b95873941e12ff856af76c0bf13b58d"},
		{"aid=8662&fixture=0", "642ce9114fee6aa2e9fb00fe388954fe744ae108"},
		{"aid=8662&fixture=19", "b4a3c72bbe58efb146b5ccd3164b20767d903b54"},
		{"aid=8662&fixture=3", "830b278a91e25a8a6ea3030b875f528c07c728e6"},
	}
	for _, sample := range samples {
		actual := hongguoMedusaHash(hongguoSM3([]byte(sample.query)), body, 1710000000)
		if hex.EncodeToString(actual) != sample.expected {
			t.Errorf("signature hash differs for %s: %x", sample.query, actual)
		}
	}
}

func TestHongguoPlaybackSignatureReference(t *testing.T) {
	entropy := hongguoPlaybackEntropy{gorgon: 0x1234, helios: 0x12345678, proto: 0xdeadbeef, launch: 7, process: 155, hash: 0x11223344, mix: 0x55667788}
	samples := []struct {
		timestamp                     int64
		query, medusa, gorgon, helios string
	}{
		{1710000000, "aid=8662&device_id=123456789012345678&ts=1710000000", "g4fsZXdvs59XUDBeVq0kFddIjX1EMwAB9TXIc2ZdA5KJOJMNAY713IbX6Ks2A4x4Z7p2BIYLgCLeGm3tsbFeRtllPsikiSeS9uNn3iBk6k/OZxi0Z+lwAbblPZZ0vsRkQC719BTrwW2I3qONIFrA52YAcSsx+oC3sBTXxwm9iIWL4VSUvXV70PPnVVhN7Xz5MGyv0EQVHYBgI3u22oGzwfMArWJKlxJN9ZwcNm3M7kjoyXg/H2Glqq37AyEXTAeB1XBWAF/Ob99jgetO/XLaajWnd5paVkYyXVZ0fsAm1urG+4WHoxZTKcvORVuji+kmFFRS5tomrzNgjLBvfOku4FfvnQX0KaoN6WcDKIEr/rs+0R0WTcPeFCc/V8y+l/djVh/oNTPqiyImSUAN1dnDvGc0YVB2KaePGxGfk9zEKTzJu/zNhoNUGdR/rAf4oygrNDe/pDLxzHlBfBbhHIzR6yKvExTlDHJysPA6/8qned3jkJew/9bO6Figdd/9Pcd0EoTWn+VEKIW0pU+ql1/Uv9X4Y6+6rFJx8ZO80IOB9rAXveshl+wBuFV+znjNauH1OM0Kg0svJdRXvIpElTaZAq3BExeOl4URKfhWDpsgNx3nZPSX+bw5lamNyoVCVY8nSAu1ebn7DAx6tFIAtfMhAb3qJf0bdd6Ajof9z8Wvc5/J5MSFPNVJhrIn7iR+p25VfAeN7Tpmbh8m51TLaO7MqhXT1/PI9xkdfZpTsi0c97cqwIkFpJR9klYiQkhARl2zTP81KAZwSGMa84LpNTC91nT+zoj658jEtyszHBlemklUPyIDQqvybixui66xJMVW9AXHFh+qIPO0oKjK6v3QoxubkFhuQyrnWCODcTFee34LQt1rtPSsJVzXxzX/QxMLbsN1n+/kPgKI4mnJIEsIxFPxvxPscok0v7X//u/N//7ujSIR", "840434124001157ff0bc05e698741364e71df6105a46efd87452", "eFY0EoJ0NrwROs4Fx2g1ZVg/AOJl2JqeXVHnmakVf60TcY/S"},
		{1710000001, "aid=8662&device_id=123456789012345678&ts=1710000001", "gofsZXZvs59WUDBeV60kFdZIjX1EMwABMTXIc2ZVAzYHGHSuxENUupIxSnx6PvNHvZ7de2SbJr8QA9czzRxlNUPj8Wz8q+6/3tI3Sdyc+W/exw28OIumhN4mi2Tx1FJeHf40TiYgz1u9TtmsIz3mP4SfIt6BxANJxjUkPSP+6jseuxJMqY24doc+7poCXUahNAEJVsE/3fjhl16dpARa1LDKwmJOTm3bGw96r/5HeXfsF6ovXK68LHjS8d3OWtwlW6TOEqd7ajjbjz3Qu8Lf64jOdw9D+nH02a5s71s35O5DZAnUt4L0b7PdFiHRwD8o1McO9Y4ZUs7g4NNg58LC4jPOuBX5zZbQuxQL3XbBsIIrRSoTaO9EtLxDOVNcHQFeqee87xn9Vd3jLrYb7xqH3agrWK6IfNsxIrrrjXjnrP9SpP/m0tzaqNP08XIYOdwK8XiAGJZIrTlgtXnD7vloW0xMejzf9du2L0DeiBXMeUIf3smITCPU604R7vA9FM7FlMdKJKTXd+5emQDEt7jLIjAqnja9D0oSkivYa0J0GmC1WGZoQJvz+lGc3X7MZJJsRb9MA42ZUhGEZfdkeXHP8fheOsfRnQhnHe/aR23gR94J1h92qRGEj86s7oc28PaLhtllTcgEouabXXJuJt3BMFRqygIfbBKfosXbPLwVfRWrTe8Fbd/OvPwPGXM/cI/peltpvowG3/L6XN0uzKxyHQL8oVWH7xodfZpTsi0c97cqwIkFpJR9klYiQkhARl2zTP81KAZwSGMa84LpNTC91nT+zoj658jEtyszHBlemklUPyIDQqvybixui66xJMVW9AXHFh+qIPO0oKjK6v3QoxubkFhuQyrnWCODcTFee34LQt1rtPSsJVzXxzX/QxMLbsN1n+/kPgKI4mnJIEsIxFPxvxPscok0v9D//u/N//7ujSIR", "84043412400128c8816605e698741364e71df6105a46efd8f4e6", "eFY0Eo1DDv2N4JGJsRXT978+yLpl2JqeXVHnmakVf60TcY/S"},
		{1710000002, "aid=8662&device_id=123456789012345678&ts=1710000002", "gYfsZXVvs59VUDBeVK0kFdVIjX1EMwABYzXId2ZdAZECGI4Q6lz6w/MSc7jVB02asQ7MJ5lcZ15Qghr+dnQLt/uLK0InI680S4yIUIdPKKBxT9zKaLOn1N966K/opyBt3Mb2dkHPneMgMWWGjqblg2gd239FDUtYtJeHwDH9oBSdprgulAbJYQb8ODDdFXuRCNU698oKLSuH8h6o+3rKm5BVEQzAmIXLj8eVuRRmmEF8ANQ/GYD4ICQMMy2nxbvlootfp4sBhUkxrQc7mjhprTgEku6ywx3rF2Y+8ze+gEyhbgcPcKaCcUcHi4yVyX1YlYcPvx1Hc7UYzOr78oXxM4rzqtz5HFh+iB4p5u0O+YkqSE0tpONggQnZfuc+uh5JPKLjyNkGSoD0MTE+fanoFQ3ekLWoYFsxor5LjNCjJu9UhPg+HcqR7LjrJM8mbYC84D7DQBEMAoBYveEfoFdr2VUGQT+OYLhYJ6LBEi6vXcQ3IS6Ol/MPhfJKuJ+8d1YiE1oh8jkJDvMtB8NQ3F+RlUcGJh98KqBgt1Bk1xMCelncGgtBtBXTZU3V+3Tyn1PbO/u4aKpJ+ZxBxL+FTiso9KnTh6GvCFp6JyWmXmnnezpiaRn/3yXTOaoxLub9DSCClLIM7bQH7odEwvfDzukIUgzKl0gAUuAO+Ka+9N1WhBnMcnWWaxzWww+V+AJVkP7CUPHWqcFFDjl3S+b6EwZ+x8gAHFxwpxMdfZpTsi0c97cqwIkFpJR9klYiQkhARl2zTP81KAZwSGMa84LpNTC91nT+zoj658jEtyszHBlemklUPyIDQqvybixui66xJMVW9AXHFh+qIPO0oKjK6v3QoxubkFhuQyrnWCODcTFee34LQt1rtPSsJVzXxzX/QxMLbsN1n+/kPgKI4mnJIEsIxFPxvxPscok0v9D//u/N//7ujSIR", "84043412400118b770aa05e698741364e71df6105a46efd834e6", "eFY0EuoKUhPR/NJg9EzZLQBF5jVl2JqeXVHnmakVf60TcY/S"},
		{1710000003, "aid=8662&device_id=123456789012345678&ts=1710000003", "gIfsZXRvs59UUDBeVa0kFdRIjX1EMwABFDXIc3ZdAWePGDrgZXxMlgNmoZbm5LEeuZaBlVccKX0FarF/0USjyv7wzoD2a0IC595+F/ePjNQ0Msjvffiirem04KuQaNYPAW710lVHlSOugbaObS0uWOGqrkvB2Xud6Jgq8gO+ipEhu/wbKVzEVzBn04q1eIjpJNg2kgi5fm5++nc51lZ3bsyxPeD9fsBW4ehoz4npta7u/yr97Ffkr0rAf5teFG6LFHFfSewQul9QnC9RkZpz371aA7584p/eMzfbcLgd89pN5iQIzqfUBxpp00bWLx1GXEBrcZ+dNVgjSV3PFMqdCAeRv7avQATAobUcwNHNyVz6Ek9H8Xf3geKGXTVLw+YnB1kr6ZjrZkpO0qS3pOx7dPkYkutckXj5mZ9psgPbGEZr1CXg2Ipu02QwBokqt1pEAbneKbFusftya723AbInniP6uJwEi20RoNfzbC/57qvdU+dyuaaH8jHlhg9qUSm/Kjzbj2gYVToaZ7Mz9yVnyNufZpoQzhvZ/5vyqmr0doMOphi1HMyF/POH56YQ2htSP1IJeotSDk66VVgpsHCwCd5XVLNoRHHn4pBOptbSb4HLYeA4mFrheZaQV06DhtKY8ms8FSOT+YspravQ6tmlD0H/aZA0u7OtkFrx2mGdfoUu8ZcCLcLmAGEn360Dy3bxUQoK0k7szoB66ugtq5JimwZaiIYynxQdfZpTsi0c97cqwIkFpJR9klYiQkhARl2zTP81KAZwSGMa84LpNTC91nT+zoj658jEtyszHBlemklUPyIDQqvybixui66xJMVW9AXHFh+qIPO0oKjK6v3QoxubkFhuQyrnWCODcTFee34LQt1rtPSsJVzXxzX/QxMLbsN1n+/kPgKI4mnJIEsIxFPxvxPscok0v27//u/N//7ujSIR", "8404341240013f2a84e205e698741364e71df6105a46efd8b40a", "eFY0EiBoApAY6WFRio4eD/YYp+9l2JqeXVHnmakVf60TcY/S"},
	}
	for _, sample := range samples {
		t.Run(fmt.Sprint(sample.timestamp), func(t *testing.T) {
			request, _ := http.NewRequest(http.MethodPost, "https://example.test/?"+sample.query, nil)
			signHongguoPlaybackRequest(request, []byte(`{"mixed_video_id_map":{"1004":["800001"]}}`), "123456789012345678", time.Unix(sample.timestamp, 0), entropy)
			for name, expected := range map[string]string{"X-Medusa": sample.medusa, "X-Gorgon": sample.gorgon, "X-Helios": sample.helios} {
				if actual := request.Header.Get(name); actual != expected {
					t.Errorf("%s differs from supplied Python implementation: %s", name, actual)
				}
			}
		})
	}
}
