// FakeSwp - writes a stand-in for a built SOLIDWORKS macro (.swp) that
// holds given VBA source, so release tests can run without SOLIDWORKS
// (the real .swp files are built locally and never committed).
//
// The file is a valid compound file ([MS-CFB] version 3) with a VBA
// project like the one SOLIDWORKS saves: a PROJECT stream, and a VBA
// storage with _VBA_PROJECT, dir (compressed per [MS-OVBA]) and one stream
// per module - 16 bytes standing in for compiled code, then the
// compressed source. tools\SwpSource.cs reads it like a real .swp.
// There is no compiled code in it; SOLIDWORKS can't run it.
//
// Keep this file ASCII.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ClaudeReview.Tests
{
    public static class FakeSwp
    {
        const int PcodeBytes = 16;
        static readonly Encoding Cp = Encoding.GetEncoding(1252);

        // A .swp built from a .bas the way importing it does: the module is
        // renamed <VB_Name>1 (it shares the project's name), and there's
        // an empty ThisLibrary module beside it.
        public static void FromBas(string swpPath, string basPath)
        {
            string text = File.ReadAllText(basPath, Cp);
            string vbName = "Module1";
            var m = System.Text.RegularExpressions.Regex.Match(text, "Attribute\\s+VB_Name\\s*=\\s*\"([^\"]+)\"");
            if (m.Success) vbName = m.Groups[1].Value;
            string module = vbName + "1";
            string source = m.Success ? text.Replace(m.Value, "Attribute VB_Name = \"" + module + "\"") : text;
            string thisLibrary = "Attribute VB_Name = \"ThisLibrary\"\r\nAttribute VB_Base = \"0{00000000-0000-0000-0000-000000000000}\"\r\n";
            Write(swpPath, vbName, new[] { "ThisLibrary", module }, new[] { thisLibrary, source });
        }

        public static void Write(string path, string projectName, string[] moduleNames, string[] sources)
        {
            if (moduleNames.Length != sources.Length) throw new ArgumentException("One source per module");

            // ---- VBA project streams ----
            var dir = new MemoryStream();
            Rec(dir, 0x0001, U32(3));            // PROJECTSYSKIND: 64-bit Windows
            Rec(dir, 0x0002, U32(0x409));        // PROJECTLCID
            Rec(dir, 0x0014, U32(0x409));        // PROJECTLCIDINVOKE
            Rec(dir, 0x0003, U16(1252));         // PROJECTCODEPAGE
            Rec(dir, 0x0004, Cp.GetBytes(projectName));
            Rec(dir, 0x0005, new byte[0]); Rec(dir, 0x0040, new byte[0]);   // doc string
            Rec(dir, 0x0006, new byte[0]); Rec(dir, 0x003D, new byte[0]);   // help file
            Rec(dir, 0x0007, U32(0));            // PROJECTHELPCONTEXT
            Rec(dir, 0x0008, U32(0));            // PROJECTLIBFLAGS
            // PROJECTVERSION: its size field is 4, but 6 bytes follow.
            dir.Write(U16(0x0009), 0, 2); dir.Write(U32(4), 0, 4); dir.Write(U32(1), 0, 4); dir.Write(U16(0), 0, 2);
            Rec(dir, 0x000C, new byte[0]); Rec(dir, 0x003C, new byte[0]);   // constants
            Rec(dir, 0x000F, U16((ushort)moduleNames.Length));
            Rec(dir, 0x0013, U16(0xFFFF));       // PROJECTCOOKIE
            var streams = new List<KeyValuePair<string, byte[]>>();
            for (int i = 0; i < moduleNames.Length; i++)
            {
                string n = moduleNames[i];
                Rec(dir, 0x0019, Cp.GetBytes(n));
                Rec(dir, 0x0047, Encoding.Unicode.GetBytes(n));
                Rec(dir, 0x001A, Cp.GetBytes(n));
                Rec(dir, 0x0032, Encoding.Unicode.GetBytes(n));
                Rec(dir, 0x001C, new byte[0]); Rec(dir, 0x0048, new byte[0]);
                Rec(dir, 0x0031, U32(PcodeBytes)); // MODULEOFFSET
                Rec(dir, 0x001E, U32(0));          // MODULEHELPCONTEXT
                Rec(dir, 0x002C, U16(0xFFFF));     // MODULECOOKIE
                Rec(dir, n == "ThisLibrary" ? 0x0022 : 0x0021, new byte[0]);
                Rec(dir, 0x002B, new byte[0]);     // module terminator
                var ms = new MemoryStream();
                ms.Write(new byte[PcodeBytes], 0, PcodeBytes);
                byte[] packed = Compress(Cp.GetBytes(sources[i]));
                ms.Write(packed, 0, packed.Length);
                streams.Add(new KeyValuePair<string, byte[]>(n, ms.ToArray()));
            }
            Rec(dir, 0x0010, new byte[0]);       // end of dir

            var project = new StringBuilder();
            project.Append("ID=\"{00000000-0000-0000-0000-000000000000}\"\r\n");
            foreach (string n in moduleNames)
                project.Append(n == "ThisLibrary" ? "Document=ThisLibrary/&H00000000\r\n" : "Module=" + n + "\r\n");
            project.Append("Name=\"" + projectName + "\"\r\n");

            // ---- Compound file ----
            var cfb = new CfbWriter();
            int root = cfb.Add("Root Entry", 5, null);
            int vba = cfb.Add("VBA", 1, null);
            cfb.Add("PROJECT", 2, Cp.GetBytes(project.ToString()));
            cfb.Children[root] = new List<int> { vba, 2 };
            var vbaChildren = new List<int>();
            vbaChildren.Add(cfb.Add("_VBA_PROJECT", 2, new byte[] { 0xCC, 0x61, 0xFF, 0xFF, 0x00, 0x00, 0x00 }));
            vbaChildren.Add(cfb.Add("dir", 2, Compress(dir.ToArray())));
            foreach (var s in streams) vbaChildren.Add(cfb.Add(s.Key, 2, s.Value));
            cfb.Children[vba] = vbaChildren;
            File.WriteAllBytes(path, cfb.ToBytes());
        }

        static void Rec(Stream s, int id, byte[] data)
        {
            s.Write(U16((ushort)id), 0, 2);
            s.Write(U32((uint)data.Length), 0, 4);
            s.Write(data, 0, data.Length);
        }
        static byte[] U16(ushort v) { return BitConverter.GetBytes(v); }
        static byte[] U32(uint v) { return BitConverter.GetBytes(v); }

        // [MS-OVBA] 2.4.1 compression: a signature byte, then one chunk per
        // 4096 bytes, each LZ77-style with copy tokens inside the chunk.
        public static byte[] Compress(byte[] data)
        {
            var output = new List<byte> { 1 };
            for (int start = 0; start < data.Length; start += 4096)
                output.AddRange(CompressChunk(data, start, Math.Min(data.Length, start + 4096)));
            return output.ToArray();
        }

        static int BitCount(int difference)
        {
            int bitCount = 4;
            while ((1 << bitCount) < difference) bitCount++;
            return bitCount;
        }

        static byte[] CompressChunk(byte[] d, int start, int end)
        {
            var body = new List<byte>(4200);
            var seen = new Dictionary<int, List<int>>();
            int pos = start;
            while (pos < end)
            {
                int flagAt = body.Count;
                body.Add(0);
                byte flags = 0;
                for (int bit = 0; bit < 8 && pos < end; bit++)
                {
                    int bestLen = 0, bestBack = 0;
                    int bitCount = BitCount(pos - start);
                    if (pos > start && pos + 3 <= end)
                    {
                        int maxLen = Math.Min((0xFFFF >> bitCount) + 3, end - pos);
                        List<int> cands;
                        if (seen.TryGetValue(Key(d, pos), out cands))
                        {
                            for (int c = cands.Count - 1, tries = 0; c >= 0 && tries < 64; c--, tries++)
                            {
                                int cand = cands[c], len = 0;
                                while (len < maxLen && d[cand + len] == d[pos + len]) len++;
                                if (len > bestLen) { bestLen = len; bestBack = pos - cand; if (len == maxLen) break; }
                            }
                        }
                    }
                    int advance = 1;
                    if (bestLen >= 3)
                    {
                        int token = ((bestBack - 1) << (16 - bitCount)) | (bestLen - 3);
                        body.Add((byte)(token & 0xFF));
                        body.Add((byte)(token >> 8));
                        flags |= (byte)(1 << bit);
                        advance = bestLen;
                    }
                    else
                    {
                        body.Add(d[pos]);
                    }
                    for (int k = 0; k < advance; k++)
                    {
                        int p = pos + k;
                        if (p + 3 > end) break;
                        List<int> list;
                        int key = Key(d, p);
                        if (!seen.TryGetValue(key, out list)) { list = new List<int>(); seen[key] = list; }
                        list.Add(p);
                    }
                    pos += advance;
                }
                body[flagAt] = flags;
            }

            var chunk = new List<byte>(body.Count + 2);
            if (body.Count > 4096)
            {
                // Didn't shrink: a raw chunk, always 4096 bytes.
                chunk.AddRange(U16(0x3FFF));
                for (int i = 0; i < 4096; i++) chunk.Add(start + i < end ? d[start + i] : (byte)0);
            }
            else
            {
                chunk.AddRange(U16((ushort)(0xB000 | (body.Count - 1))));
                chunk.AddRange(body);
            }
            return chunk.ToArray();
        }

        static int Key(byte[] d, int p) { return d[p] | (d[p + 1] << 8) | (d[p + 2] << 16); }
    }

    // A small [MS-CFB] version 3 writer (512-byte sectors, one level of
    // DIFAT in the header, so up to ~7 MB): enough for a test macro.
    internal sealed class CfbWriter
    {
        const uint EndOfChain = 0xFFFFFFFE, FreeSect = 0xFFFFFFFF, FatSect = 0xFFFFFFFD, NoStream = 0xFFFFFFFF;
        const int Sector = 512, Mini = 64, Cutoff = 4096;

        readonly List<string> _names = new List<string>();
        readonly List<int> _types = new List<int>();
        readonly List<byte[]> _data = new List<byte[]>();
        public readonly Dictionary<int, List<int>> Children = new Dictionary<int, List<int>>();

        public int Add(string name, int type, byte[] data)
        {
            _names.Add(name); _types.Add(type); _data.Add(data);
            return _names.Count - 1;
        }

        public byte[] ToBytes()
        {
            int n = _names.Count;
            var left = new uint[n]; var right = new uint[n]; var child = new uint[n];
            var start = new uint[n]; var size = new long[n];
            for (int i = 0; i < n; i++) { left[i] = right[i] = child[i] = NoStream; }

            // Siblings as a chain in [MS-CFB] order (shorter names first,
            // then upper-case comparison), each the right child of the last.
            foreach (var kv in Children)
            {
                var kids = new List<int>(kv.Value);
                kids.Sort((a, b) =>
                {
                    int c = _names[a].Length.CompareTo(_names[b].Length);
                    return c != 0 ? c : string.CompareOrdinal(_names[a].ToUpperInvariant(), _names[b].ToUpperInvariant());
                });
                if (kids.Count > 0) child[kv.Key] = (uint)kids[0];
                for (int k = 0; k + 1 < kids.Count; k++) right[kids[k]] = (uint)kids[k + 1];
            }

            // Small streams go in the mini stream, the rest in sectors.
            var mini = new MemoryStream();
            var miniFat = new List<uint>();
            var big = new List<int>();
            for (int i = 0; i < n; i++)
            {
                if (_types[i] != 2) continue;
                byte[] d = _data[i] ?? new byte[0];
                size[i] = d.Length;
                if (d.Length == 0) { start[i] = EndOfChain; continue; }
                if (d.Length >= Cutoff) { big.Add(i); continue; }
                int first = miniFat.Count;
                int count = (d.Length + Mini - 1) / Mini;
                mini.Write(d, 0, d.Length);
                mini.Write(new byte[count * Mini - d.Length], 0, count * Mini - d.Length);
                for (int k = 0; k < count; k++) miniFat.Add(k + 1 < count ? (uint)(first + k + 1) : EndOfChain);
                start[i] = (uint)first;
            }
            byte[] miniBytes = mini.ToArray();

            int dirSectors = (n * 128 + Sector - 1) / Sector;
            int miniFatSectors = (miniFat.Count * 4 + Sector - 1) / Sector;
            int miniSectors = (miniBytes.Length + Sector - 1) / Sector;
            int bigSectors = 0;
            foreach (int i in big) bigSectors += (_data[i].Length + Sector - 1) / Sector;
            int other = dirSectors + miniFatSectors + miniSectors + bigSectors;
            int fatSectors = 1;
            while (fatSectors * (Sector / 4) < other + fatSectors) fatSectors++;
            if (fatSectors > 109) throw new InvalidOperationException("Too big for this writer");

            int total = fatSectors + other;
            var fat = new uint[fatSectors * (Sector / 4)];
            for (int i = 0; i < fat.Length; i++) fat[i] = FreeSect;
            for (int i = 0; i < fatSectors; i++) fat[i] = FatSect;
            int next = fatSectors;
            Func<int, uint> chain = count =>
            {
                if (count == 0) return EndOfChain;
                int first = next;
                for (int k = 0; k < count; k++) fat[first + k] = k + 1 < count ? (uint)(first + k + 1) : EndOfChain;
                next += count;
                return (uint)first;
            };
            uint dirStart = chain(dirSectors);
            uint miniFatStart = chain(miniFatSectors);
            uint miniStart = chain(miniSectors);
            foreach (int i in big) start[i] = chain((_data[i].Length + Sector - 1) / Sector);
            start[0] = miniBytes.Length > 0 ? miniStart : EndOfChain;
            size[0] = miniBytes.Length;

            var file = new byte[(total + 1) * Sector];
            // Header
            Put(file, 0, BitConverter.GetBytes(0xE11AB1A1E011CFD0UL));
            Put(file, 0x18, U16(0x003E)); Put(file, 0x1A, U16(0x0003)); Put(file, 0x1C, U16(0xFFFE));
            Put(file, 0x1E, U16(9)); Put(file, 0x20, U16(6));
            Put(file, 0x2C, U32((uint)fatSectors));
            Put(file, 0x30, U32(dirStart));
            Put(file, 0x38, U32(Cutoff));
            Put(file, 0x3C, U32(miniFatSectors > 0 ? miniFatStart : EndOfChain));
            Put(file, 0x40, U32((uint)miniFatSectors));
            Put(file, 0x44, U32(EndOfChain));
            for (int i = 0; i < 109; i++) Put(file, 0x4C + i * 4, U32(i < fatSectors ? (uint)i : FreeSect));
            // FAT
            for (int i = 0; i < fat.Length; i++) Put(file, Sector + i * 4, U32(fat[i]));
            // Directory
            var dir = new byte[dirSectors * Sector];
            for (int i = 0; i < dirSectors * 4; i++)
            {
                int o = i * 128;
                Put(dir, o + 0x44, U32(NoStream)); Put(dir, o + 0x48, U32(NoStream)); Put(dir, o + 0x4C, U32(NoStream));
                if (i >= n) continue;
                byte[] nm = Encoding.Unicode.GetBytes(_names[i]);
                Put(dir, o, nm);
                Put(dir, o + 0x40, U16((ushort)(nm.Length + 2)));
                dir[o + 0x42] = (byte)_types[i];
                dir[o + 0x43] = 1; // black
                Put(dir, o + 0x44, U32(left[i])); Put(dir, o + 0x48, U32(right[i])); Put(dir, o + 0x4C, U32(child[i]));
                Put(dir, o + 0x74, U32(_types[i] == 1 ? 0 : start[i]));
                Put(dir, o + 0x78, BitConverter.GetBytes((ulong)size[i]));
            }
            Put(file, (int)(dirStart + 1) * Sector, dir);
            // MiniFAT, padded with free entries
            if (miniFatSectors > 0)
            {
                int o = (int)(miniFatStart + 1) * Sector;
                for (int i = 0; i < miniFatSectors * (Sector / 4); i++)
                    Put(file, o + i * 4, U32(i < miniFat.Count ? miniFat[i] : FreeSect));
            }
            if (miniSectors > 0) Put(file, (int)(miniStart + 1) * Sector, miniBytes);
            foreach (int i in big) Put(file, (int)(start[i] + 1) * Sector, _data[i]);
            return file;
        }

        static void Put(byte[] dst, int at, byte[] src) { Buffer.BlockCopy(src, 0, dst, at, src.Length); }
        static byte[] U16(ushort v) { return BitConverter.GetBytes(v); }
        static byte[] U32(uint v) { return BitConverter.GetBytes(v); }
    }
}
