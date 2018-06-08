{
package BitcoinCash;
    use strict;
    use warnings;
    use Business::Bitcoin::Request;

    sub getaddress {
      my ($xpub, $index, %arg) = @_;
      $arg{electron_cash} //= !!1;
      $arg{old} //= !!0;

      $xpub =~ /^xpub6/ or die "invalid xpub6\n";

      local $SIG{__WARN__} = sub { die @_ };

      # my $xpub = $bizbtc->xpub;
      my $curve = Math::EllipticCurve::Prime->from_name('secp256k1');
      my $xpubdata =  Math::BigInt->new(Business::Bitcoin::Request::_decode58($xpub))->as_hex;
      # $xpubdata =~ /.(.{8})(..)(.{8})(.{8})(.{64})(.{66})(.*)/;
      # my ($ver, $depth, $fp, $i, $c, $Kc) = ($1, $2, $3, $4, $5, $6);
      my ($ver, $depth, $fp, $i, $c, $Kc) = $xpubdata =~ /.(.{8})(..)(.{8})(.{8})(.{64})(.{66})(.*)/
        or die "invalid xpubdata";

      #print time, " t1\n";
      my $K = Math::EllipticCurve::Prime::Point->from_hex(Business::Bitcoin::Request::_decompress($Kc));
      my $ret;
      #print time, " t2\n";
      if ($arg{electron_cash}) {
        # m/0
        my ($Ki, $ci) = Business::Bitcoin::Request::_CKDpub($K, $c, 0);
        #print time, " t3\n";
        # m/0/$index
        my ($Ki2, $ci2) = Business::Bitcoin::Request::_CKDpub($Ki, $ci, $index);
        #print time, " t4\n";
        $ret = Business::Bitcoin::Request::_address(Business::Bitcoin::Request::_compress($Ki2));
        #print time, " t5\n";
      }
      else {
        my ($Ki, $ci) = Business::Bitcoin::Request::_CKDpub($K, $c, $index);
        $ret = Business::Bitcoin::Request::_address(Business::Bitcoin::Request::_compress($Ki));
      }

      return $arg{old} ? $ret : CashAddress::old2new($ret);
    }
}


BEGIN {
package CashAddress;
    use strict;
    use warnings;
    use bigint 'hex';
    use Digest::SHA 'sha256_hex';

    my $ALPHABET = [ split //, "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" ];
    my $CHARSET = [ split //, "qpzry9x8gf2tvdw0s3jn54khce6mua7l" ];
    my $ALPHABET_MAP = {
        "1" => 0, "2" => 1, "3" => 2, "4" => 3, "5" => 4, "6" => 5, "7" => 6,
        "8" => 7, "9" => 8, "A" => 9, "B" => 10, "C" => 11, "D" => 12, "E" => 13, "F" => 14, "G" => 15,
        "H" => 16, "J" => 17, "K" => 18, "L" => 19, "M" => 20, "N" => 21, "P" => 22, "Q" => 23, "R" => 24,
        "S" => 25, "T" => 26, "U" => 27, "V" => 28, "W" => 29, "X" => 30, "Y" => 31, "Z" => 32, "a" => 33,
        "b" => 34, "c" => 35, "d" => 36, "e" => 37, "f" => 38, "g" => 39, "h" => 40, "i" => 41, "j" => 42,
        "k" => 43, "m" => 44, "n" => 45, "o" => 46, "p" => 47, "q" => 48, "r" => 49, "s" => 50, "t" => 51,
        "u" => 52, "v" => 53, "w" => 54, "x" => 55, "y" => 56, "z" => 57
    };
    my $BECH_ALPHABET = {"q" => 0, "p" => 1,
                          "z" => 2, "r" => 3, "y" => 4, "9" => 5, "x" => 6, "8" => 7,
                          "g" => 8, "f" => 9, "2" => 10, "t" => 11, "v" => 12, "d" => 13,
                          "w" => 14, "0" => 15, "s" => 16, "3" => 17, "j" => 18, "n" => 19,
                          "5" => 20, "4" => 21, "k" => 22, "h" => 23, "c" => 24, "e" => 25,
                          "6" => 26, "m" => 27, "u" => 28, "a" => 29, "7" => 30, "l" => 31
    };
    my $EXPAND_PREFIX = [2, 9, 20, 3, 15, 9, 14, 3, 1, 19, 8, 0];
    my $EXPAND_PREFIX_TESTNET = [2, 3, 8, 20, 5, 19, 20, 0];
    my $BASE16 = {"0" => 0, "1" => 1, "2" => 2, "3" => 3,
                          "4" => 4, "5" => 5, "6" => 6, "7" => 7,
                            "8" => 8, "9" => 9, "a" => 10, "b" => 11,
                            "c" => 12, "d" => 13, "e" => 14, "f" => 15
    };

    # /**
     # * convertBits is the internal function to convert 256-based bytes
     # * to base-32 grouped bit arrays and vice versa.
     # * @param  array $data Data whose bits to be re-grouped
     # * @param  integer $fromBits Bits per input group of the $data
     # * @param  integer $toBits Bits to be put to each output group
     # * @param  boolean $pad Whether to add extra zeroes
     # * @return array $ret
     # * @throws CashAddressException
     # */
    sub convertBits
    {
        my ($data, $fromBits, $toBits, $pad) = @_;
        $pad //= 1;

        my $acc    = 0;
        my $bits   = 0;
        my $ret    = [];
        my $maxv   = (1 << $toBits) - 1;
        my $maxacc = (1 << ($fromBits + $toBits - 1)) - 1;

        # for ($i = 0; $i < sizeof($data); $i++)
        for my $value (@$data) {
            # $value = $data[$i];

            if ($value < 0 || $value >> $fromBits != 0)
            {
                die("Error!");
            }

            $acc  = (($acc << $fromBits) | $value) & $maxacc;
            $bits += $fromBits;

            while ($bits >= $toBits)
            {
                $bits  -= $toBits;
                push @$ret, (($acc >> $bits) & $maxv);
            }
        }

        if ($pad)
        {
            if ($bits)
            {
                push @$ret, ($acc << $toBits - $bits) & $maxv;
            }
        }
        elsif ($bits >= $fromBits || ((($acc << ($toBits - $bits))) & $maxv))
        {
            die("Error!");
        }

        return $ret;
    }

    # /**
    # * polyMod is the internal function create BCH codes.
    # * @param  array $var 5-bit grouped data array whose polyMod to be calculated.
    # * @return integer $polymodValue polymod result
    # */
    sub polyMod
    {
        my ($var) = @_;
        
        my $c = 1;

        # for ($i = 0; $i < sizeof($var); $i++)
        for my $v (@$var)
        {
            my $c0 = $c >> 35;
            $c = (($c & hex("0x07ffffffff")) << 5) ^ $v;
            if ($c0 & 1)
            {
                $c ^= hex("0x98f2bc8e61");
            }
            if ($c0 & 2)
            {
                $c ^= hex("0x79b76d99e2");
            }
            if ($c0 & 4)
            {
                $c ^= hex("0xf33e5fb3c4");
            }
            if ($c0 & 8)
            {
                $c ^= hex("0xae2eabe2a8");
            }
            if ($c0 & 16)
            {
                $c ^= hex("0x1e4f43e470");
            }
        }

        return $c ^ 1;
    }

    # /**
    # * rebuildAddress is the internal function to recreate error
    # * corrected addresses.
    # * @param  array $addressBytes
    # * @return string $correctedAddress
    # */
    sub rebuildAddress
    {
        my ($addressBytes) = @_;
        
        my $ret = "";
        my $i   = 0;

        while ($addressBytes->[$i] != 0)
        {
            # // 96 = ord('a') & 0xe0
            $ret .= chr(96 + $addressBytes->[$i]);
            $i++;
        }

        $ret .= ':';

        for ($i++; $i < @$addressBytes; $i++)
        {
            $ret .= $CHARSET->[ $addressBytes->[$i] ];
        }

        return $ret;
    }

    # /**
    # * old2new converts an address in old format to the new Cash Address format.
    # * @param  string $oldAddress (either Mainnet or Testnet)
    # * @return string $newAddress Cash Address result
    # * @throws CashAddressException
    # */
    sub old2new
    {
        my ($oldAddressStr) = @_;
        my $oldAddress = [ split //, $oldAddressStr ];
        my $bytes = [0];

        # for ($x = 0; $x < strlen($oldAddress); $x++)
        for my $x (0 .. $#$oldAddress)
        {
            # if (!array_key_exists($oldAddress[$x], self::ALPHABET_MAP))
            if (!exists $ALPHABET_MAP->{$oldAddress->[$x]} )
            {
                die('Unexpected character in address!');
            }

            my $value = $ALPHABET_MAP->{$oldAddress->[$x]};
            my $carry = $value;

            # for ($j = 0; $j < @$bytes; $j++)
            for my $v (@$bytes)
            {
                # $carry     += $bytes[$j] * 58;
                $carry     += $v * 58;
                # $bytes[$j] = $carry & 0xff;
                $v = $carry & 0xff;
                $carry     >>= 8;
            }

            while ($carry > 0)
            {
                push(@$bytes, $carry & 0xff);
                $carry >>= 8;
            }
        }

        for (my $numZeros = 0; $numZeros < @$oldAddress && $oldAddress->[$numZeros] eq "1"; $numZeros++)
        {
            push(@$bytes, 0);
        }

        # // reverse array
        my $answer = [];

        for (my $i = @$bytes - 1; $i >= 0; $i--)
        {
            push(@$answer, $bytes->[$i]);
        }

        my $version = $answer->[0];
        # my $payload = array_slice($answer, 1, sizeof($answer) - 5);
        # my $payload = [ splice(@$answer, 1, @$answer -5) ];
        my $payload = [ @$answer[ 1 .. @$answer -5 ] ];

        if (@$payload % 4 != 0)
        {
            die('Unexpected address length!', @$payload*1);
        }

        # // Assume the checksum of the old address is right
        # // Here, the Cash Address conversion starts
        my $addressType;
        my $realNet;
        if ($version == 0x00)
        {
            # // P2PKH
            $addressType = 0;
            $realNet = 1;
        }
        elsif ($version == 0x05)
        {
            # // P2SH
            $addressType = 1;
            $realNet = 1;
        }
        elsif ($version == 0x6f)
        {
            # // Testnet P2PKH
            $addressType = 0;
            $realNet = 0;
        }
        elsif ($version == 0xc4)
        {
            # // Testnet P2SH
            $addressType = 1;
            $realNet = 0;
        }
        elsif ($version == 0x1c)
        {
            # // BitPay P2PKH
            $addressType = 0;
            $realNet = 1;
        }
        elsif ($version == 0x28)
        {
            # // BitPay P2SH
            $addressType = 1;
            $realNet = 1;
        }
        else
        {
            die('Unknown address type!');
        }

        my $encodedSize = (@$payload - 20) / 4;

        my $versionByte      = ($addressType << 3) | $encodedSize;
        # $data             = array_merge([$versionByte], $payload);
        my $data             = [$versionByte, @$payload];
        my $payloadConverted = convertBits($data, 8, 5, !!1);

        my $arr;
        my $ret;
        if ($realNet) {
            # $arr = array_merge(self::EXPAND_PREFIX, $payloadConverted, [0, 0, 0, 0, 0, 0, 0, 0]);
            $arr = [ @$EXPAND_PREFIX, @$payloadConverted, 0, 0, 0, 0, 0, 0, 0, 0 ];
            $ret = "bitcoincash:";
        } else {
            # $arr = array_merge(self::EXPAND_PREFIX_TESTNET, $payloadConverted, [0, 0, 0, 0, 0, 0, 0, 0]);
            $arr = [ @$EXPAND_PREFIX_TESTNET, @$payloadConverted,  0, 0, 0, 0, 0, 0, 0, 0 ];
            $ret = "bchtest:";
        }
        my $mod          = polyMod($arr);
        my $checksum     = [0, 0, 0, 0, 0, 0, 0, 0];

        for (my $i = 0; $i < 8; $i++)
        {
            # // Convert the 5-bit groups in mod to checksum values.
            # // $checksum[$i] = ($mod >> 5*(7-$i)) & 0x1f;
            $checksum->[$i] = ($mod >> (5 * (7 - $i))) & 0x1f;
        }

        my $combined = [ @$payloadConverted, @$checksum ];

        # for ($i = 0; $i < sizeof($combined); $i++)
        for my $v (@$combined)
        {
            $ret .= $CHARSET->[$v];
        }

        return $ret;
    }

    # /**
     # * Decodes Cash Address.
     # * @param  string $inputNew New address to be decoded.
     # * @param  boolean $shouldFixErrors Whether to fix typing errors.
     # * @param  boolean &$isTestnetAddressResult Is pointer, set to whether it's
     # * a testnet address.
     # * @return array $decoded Returns decoded byte array if it can be decoded.
     # * @return string $correctedAddress Returns the corrected address if there's
     # * a typing error.
     # * @throws CashAddressException
     # */
    # static public function decodeNewAddr($inputNew, $shouldFixErrors, &$isTestnetAddressResult)
    sub decodeNewAddr {
        my ($inputNewStr, $shouldFixErrors, $isTestnetAddressResult) = @_;
        $isTestnetAddressResult = \$_[2];
        
        $inputNewStr = lc($inputNewStr);
        my $afterPrefix;
        my $data;
        my $inputNew = [ split //, $inputNewStr ];
        if ($inputNewStr !~ /:/) {
            $afterPrefix = 0;
            $data = $EXPAND_PREFIX;
            $$isTestnetAddressResult = !!0;
        }
        elsif ($inputNewStr =~ /^bitcoincash:/)
        {
            $afterPrefix = 12;
            $data = $EXPAND_PREFIX;
            $$isTestnetAddressResult = !!0;
        }
        elsif ($inputNewStr =~ /^bchtest:/)
        {
            $afterPrefix = 8;
            $data = $EXPAND_PREFIX_TESTNET;
            $$isTestnetAddressResult = !!1;
        }
        else
        {
            die('Unknown address type');
        }

        my $values;
        for ($values = []; $afterPrefix < @$inputNew; $afterPrefix++)
        {
            # if (!array_key_exists($inputNew[$afterPrefix], self::BECH_ALPHABET))
            if (!exists $BECH_ALPHABET->{ $inputNew->[$afterPrefix] })
            {
                die('Unexpected character in address!');
            }
            push(@$values, $BECH_ALPHABET->{ $inputNew->[$afterPrefix] });
        }

        # $data     = array_merge($data, $values);
        push @$data, @$values;
        my $checksum = polyMod($data);

        if ($checksum != 0)
        {
            # // Checksum is wrong!
            # // Try to fix up to two errors
            if ($shouldFixErrors) {
                my $syndromes = {};

                for (my $p = 0; $p < @$data; $p++)
                {
                    for (my $e = 1; $e < 32; $e++)
                    {
                        $data->[$p] ^= $e;
                        my $c = polyMod($data);
                        if ($c == 0)
                        {
                            return rebuildAddress($data);
                        }
                        $syndromes->{$c ^ $checksum} = $p * 32 + $e;
                        $data->[$p]                  ^= $e;
                    }
                }

                # foreach ($syndromes as $s0 => $pe)
                foreach my $s0 (keys %$syndromes)
                {
                    my $pe = $syndromes->{$s0};
                    # if (array_key_exists($s0 ^ $checksum, $syndromes))
                    if (exists $syndromes->{$s0 ^ $checksum})
                    {
                        $data->[$pe >> 5]                         ^= $pe % 32;
                        $data->[$syndromes->{$s0 ^ $checksum} >> 5] ^= $syndromes->{$s0 ^ $checksum} % 32;
                        return rebuildAddress($data);
                    }
                }
                # // Can't correct errors!
                die('Can\'t correct typing errors!');
            }
        }
        return $values;
    }

    # /**
     # * Corrects Cash Address typing errors.
     # * @param  string $inputNew Cash Address to be corrected.
     # * @return string $correctedAddress Error corrected address, or the input itself
     # * if there are no errors.
     # * @throws CashAddressException
     # */
    sub fixCashAddrErrors {
        my ($inputNew) = @_;
        my $ok = eval {
            my $corrected = decodeNewAddr($inputNew, !!1, my $isTestnet);
            if (ref($corrected) eq "ARRAY") {
                return $inputNew;
            }
            else {
                return $corrected;
            }
        };
        $ok or die $@;
    }


    # /**
    # * new2old converts an address in the Cash Address format to the old format.
    # * @param  string $inputNew Cash Address (either mainnet or testnet)
    # * @param  boolean $shouldFixErrors Whether to fix typing errors.
    # * @return string $oldAddress Old style 1... or 3... address
    # * @throws CashAddressException
    # */
    sub __new2old
    {
        my ($inputNew, $shouldFixErrors) = @_;
        
        my $values;
        my $isTestnet;
        my $ok = eval {
            my $corrected = decodeNewAddr($inputNew, $shouldFixErrors, $isTestnet);
            if (ref($corrected) eq "ARRAY") {
                $values = $corrected;
            }
            else {
                $values = decodeNewAddr($corrected, !!0, $isTestnet);
            }
        };
        $ok or die ('Error'); # $@;

        # $values      = convertBits(array_slice($values, 0, @$values -8), 5, 8, !!0);
        $values      = convertBits([@$values[ 0 .. @$values -8]], 5, 8, !!0);
        my $addressType = $values->[0] >> 3;
        # my $addressHash = array_slice($values, 1, 21);
        my $addressHash = @$values[ 1 .. 1+21 ];

        # // Encode Address
        my $bytes;
        if ($isTestnet) {
            if ($addressType) {
                $bytes = [0xc4];
            } else {
                $bytes = [0x6f];
            }
        }
        else {
            if ($addressType) {
                $bytes = [0x05];
            } else {
                $bytes = [0x00];
            }
        }
        # $bytes  = array_merge($bytes, $addressHash);
        push @$bytes, @$addressHash;
        # $merged = array_merge($bytes, self::doubleSha256ByteArray($bytes));
        my $merged = [ @$bytes, @{doubleSha256ByteArray($bytes)} ];

        my $digits = [0];

        # for ($i = 0; $i < sizeof($merged); $i++)
        for my $carry (@$merged)
        {
            # $carry = $merged[$i];
            # for ($j = 0; $j < sizeof($digits); $j++)
            for my $val (@$digits)
            {
                $carry      += $val << 8;
                $val        = $carry % 58;
                $carry      = int($carry/ 58);
            }

            while ($carry > 0)
            {
                push(@$digits, $carry % 58);
                $carry = int($carry/ 58);
            }
        }

        # // leading zero bytes
        for (my $i = 0; $i < @$merged && $merged->[$i] == 0; $i++)
        {
            push(@$digits, 0);
        }

        # // reverse
        my $converted = "";
        for (my $i = @$digits - 1; $i >= 0; $i--)
        {
            if ($digits->[$i] > @$ALPHABET)
            {
                die('Error!');
            }
            $converted .= $ALPHABET->[$digits->[$i]];
        }

        return $converted;
    }

    # /**
     # * internal function to calculate sha256
     # * @param  array $byteArray Byte array of data to be hashed
     # * @return array $hashResult First four bytes of sha256 result
     # */
    sub doubleSha256ByteArray {
        my ($byteArray) = @_;
        
        my $stringToBeHashed = "";
        for my $v (@$byteArray)
        {
            $stringToBeHashed .= chr($v);
        }
        my $hash = [ split //, sha256_hex($stringToBeHashed) ];
        my $hashArray = [];
        for (my $i = 0; $i < 32; $i++)
        {
            push(@$hashArray, $BASE16->{$hash->[2 * $i]} * 16 + $BASE16->{$hash->[2 * $i + 1]});
        }

        $stringToBeHashed = "";
        for my $v (@$hashArray)
        {
            $stringToBeHashed .= chr($v);
        }

        $hashArray = [];
        $hash      = [ split //, sha256_hex($stringToBeHashed) ];
        for (my $i = 0; $i < 4; $i++)
        {
            push(@$hashArray, $BASE16->{$hash->[2 * $i]} * 16 + $BASE16->{$hash->[2 * $i + 1]});
        }
        return $hashArray;
    }
    
    # sub hash{}
}

1;

