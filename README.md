# Apple BSSID Locator
This standalone bash script queries Apple Location Services to look up the approximate position of a Wi-Fi access point by its BSSID (MAC address), and can optionally open the resolved coordinates in Google Maps.

## Usage
1. Make the script executable
   ```bash
   chmod +x query.sh
   ```
2. Look up a single BSSID:
   ```bash
   ./query.sh <BSSID>
   ```
3. Show every BSSID Apple returns for the query:
   ```bash
   ./query.sh <BSSID> -a
   ```
4. Open the location in Google Maps (macOS `open` command):
   ```bash
   ./query.sh <BSSID> -m
   ```
Arguments can be combined, for example `./query.sh <BSSID> -a -m` or `./query.sh <BSSID> -am` to list all results and open each in the browser.

## Credits
- [iSniff-GPS](https://github.com/hubert3/iSniff-GPS) by hubert3
- Research by François-Xavier Aguessy and Côme Demoustier: [Interception SSL & Analyse Données Localisation Smartphones](http://fxaguessy.fr/rapport-pfe-interception-ssl-analyse-donnees-localisation-smartphones/)
- A Python implementation: [darkosancanin/apple_bssid_locator](https://github.com/darkosancanin/apple_bssid_locator)

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
