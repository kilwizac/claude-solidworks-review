// SwpSource - reads the VBA source code out of a SOLIDWORKS macro (.swp).
//
// A .swp is an OLE compound file holding a standard VBA project
// ([MS-CFB] and [MS-OVBA]). The "dir" stream lists the modules; each
// module stream holds compiled code followed, at the module's offset, by
// its source in the VBA compressed format. Nothing here needs SOLIDWORKS,
// so release checks can run on any Windows machine.
//
// Used by tools\SwpSource.psm1. Keep this file ASCII.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;

namespace ClaudeReview
{
    public sealed class VbaModule
    {
        public string Name;
        public string StreamName;
        public string Source;
    }

    public static class SwpSource
    {
        // Every module in the macro, in project order.
        public static List<VbaModule> ReadModules(string path)
        {
            byte[] file;
            // SOLIDWORKS may hold the .swp open: read with shared access.
            using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                file = new byte[fs.Length];
                int read = 0;
                while (read < file.Length)
                {
                    int n = fs.Read(file, read, file.Length - read);
                    if (n <= 0) throw new EndOfStreamException(path);
                    read += n;
                }
            }
            var cfb = new CompoundFile(file);
            int vba = cfb.FindStorageWithStream("VBA", "dir");
            if (vba < 0) throw new InvalidDataException("No VBA project in " + path);

            byte[] dir = Decompress(cfb.ReadStream(cfb.FindChild(vba, "dir")), 0);
            var modules = new List<VbaModule>();
            Encoding cp = Encoding.GetEncoding(1252);
            int pos = 0;
            VbaModule cur = null;
            uint offset = 0;
            while (pos + 6 <= dir.Length)
            {
                int id = BitConverter.ToUInt16(dir, pos);
                int size = (int)BitConverter.ToUInt32(dir, pos + 2);
                // PROJECTVERSION's size field says 4, but 6 bytes follow it.
                if (id == 0x0009) size = 6;
                int data = pos + 6;
                if (data + size > dir.Length) break;
                switch (id)
                {
                    case 0x0003: // PROJECTCODEPAGE
                        try { cp = Encoding.GetEncoding(BitConverter.ToUInt16(dir, data)); } catch { }
                        break;
                    case 0x0019: // MODULENAME
                        cur = new VbaModule { Name = cp.GetString(dir, data, size) };
                        offset = 0;
                        break;
                    case 0x0047: // MODULENAMEUNICODE
                        if (cur != null) cur.Name = Encoding.Unicode.GetString(dir, data, size);
                        break;
                    case 0x001A: // MODULESTREAMNAME
                        if (cur != null) cur.StreamName = cp.GetString(dir, data, size);
                        break;
                    case 0x0032: // MODULESTREAMNAMEUNICODE
                        if (cur != null) cur.StreamName = Encoding.Unicode.GetString(dir, data, size);
                        break;
                    case 0x0031: // MODULEOFFSET
                        offset = BitConverter.ToUInt32(dir, data);
                        break;
                    case 0x002B: // module terminator
                        if (cur != null)
                        {
                            int child = cfb.FindChild(vba, cur.StreamName ?? cur.Name);
                            if (child >= 0)
                            {
                                byte[] stream = cfb.ReadStream(child);
                                cur.Source = cp.GetString(Decompress(stream, (int)offset));
                            }
                            modules.Add(cur);
                            cur = null;
                        }
                        break;
                }
                pos = data + size;
                if (id == 0x0010) break; // end of dir
            }
            return modules;
        }

        // [MS-OVBA] 2.4.1 decompression of a CompressedContainer at start.
        public static byte[] Decompress(byte[] buf, int start)
        {
            var output = new List<byte>(buf.Length * 3);
            if (start >= buf.Length) return output.ToArray();
            if (buf[start] != 1) throw new InvalidDataException("Not a VBA compressed container");
            int pos = start + 1;
            while (pos + 2 <= buf.Length)
            {
                int header = BitConverter.ToUInt16(buf, pos);
                int chunkSize = (header & 0x0FFF) + 3;
                bool compressed = (header & 0x8000) != 0;
                int chunkEnd = Math.Min(buf.Length, pos + chunkSize);
                pos += 2;
                int chunkStart = output.Count;
                if (!compressed)
                {
                    for (int i = 0; i < 4096 && pos < buf.Length; i++) output.Add(buf[pos++]);
                    continue;
                }
                while (pos < chunkEnd)
                {
                    byte flags = buf[pos++];
                    for (int bit = 0; bit < 8 && pos < chunkEnd; bit++)
                    {
                        if ((flags & (1 << bit)) == 0)
                        {
                            output.Add(buf[pos++]);
                            continue;
                        }
                        if (pos + 2 > chunkEnd) { pos = chunkEnd; break; }
                        int token = BitConverter.ToUInt16(buf, pos);
                        pos += 2;
                        int difference = output.Count - chunkStart;
                        int bitCount = 4;
                        while ((1 << bitCount) < difference) bitCount++;
                        int lengthMask = 0xFFFF >> bitCount;
                        int length = (token & lengthMask) + 3;
                        int back = (token >> (16 - bitCount)) + 1;
                        int from = output.Count - back;
                        if (from < 0) throw new InvalidDataException("Bad VBA copy token");
                        for (int k = 0; k < length; k++) output.Add(output[from + k]);
                    }
                }
                pos = chunkEnd;
            }
            return output.ToArray();
        }
    }

    // Just enough of [MS-CFB] to read streams by name.
    internal sealed class CompoundFile
    {
        const uint EndOfChain = 0xFFFFFFFE;
        const uint FreeSect = 0xFFFFFFFF;
        readonly byte[] _f;
        readonly int _sector;
        readonly int _mini;
        readonly uint _cutoff;
        readonly List<uint> _fat = new List<uint>();
        readonly List<uint> _miniFat = new List<uint>();
        readonly List<Entry> _dir = new List<Entry>();
        byte[] _miniStream;

        internal sealed class Entry
        {
            public string Name;
            public int Type; // 1 storage, 2 stream, 5 root
            public int Left, Right, Child;
            public uint Start;
            public long Size;
        }

        public CompoundFile(byte[] f)
        {
            _f = f;
            if (f.Length < 512 || BitConverter.ToUInt64(f, 0) != 0xE11AB1A1E011CFD0UL)
                throw new InvalidDataException("Not an OLE compound file (a .swp is one)");
            _sector = 1 << BitConverter.ToUInt16(f, 0x1E);
            _mini = 1 << BitConverter.ToUInt16(f, 0x20);
            _cutoff = BitConverter.ToUInt32(f, 0x38);

            // FAT sectors: 109 in the header, the rest chained through DIFAT.
            var fatSectors = new List<uint>();
            for (int i = 0; i < 109; i++)
            {
                uint s = BitConverter.ToUInt32(f, 0x4C + i * 4);
                if (s != FreeSect) fatSectors.Add(s);
            }
            uint difat = BitConverter.ToUInt32(f, 0x44);
            int perSector = _sector / 4;
            int guard = 0;
            while (difat != EndOfChain && difat != FreeSect && guard++ < 100000)
            {
                long off = SectorOffset(difat);
                for (int i = 0; i < perSector - 1; i++)
                {
                    uint s = BitConverter.ToUInt32(f, (int)(off + i * 4));
                    if (s != FreeSect) fatSectors.Add(s);
                }
                difat = BitConverter.ToUInt32(f, (int)(off + (perSector - 1) * 4));
            }
            foreach (uint s in fatSectors)
            {
                long off = SectorOffset(s);
                for (int i = 0; i < perSector && off + i * 4 + 4 <= f.Length; i++)
                    _fat.Add(BitConverter.ToUInt32(f, (int)(off + i * 4)));
            }

            byte[] dirBytes = ReadChain(BitConverter.ToUInt32(f, 0x30), -1);
            for (int i = 0; i + 128 <= dirBytes.Length; i += 128)
            {
                int nameLen = BitConverter.ToUInt16(dirBytes, i + 0x40);
                var e = new Entry
                {
                    Name = nameLen >= 2 ? Encoding.Unicode.GetString(dirBytes, i, nameLen - 2) : "",
                    Type = dirBytes[i + 0x42],
                    Left = BitConverter.ToInt32(dirBytes, i + 0x44),
                    Right = BitConverter.ToInt32(dirBytes, i + 0x48),
                    Child = BitConverter.ToInt32(dirBytes, i + 0x4C),
                    Start = BitConverter.ToUInt32(dirBytes, i + 0x74),
                    Size = BitConverter.ToUInt32(dirBytes, i + 0x78)
                };
                _dir.Add(e);
            }

            byte[] miniFatBytes = ReadChain(BitConverter.ToUInt32(f, 0x3C), -1);
            for (int i = 0; i + 4 <= miniFatBytes.Length; i += 4) _miniFat.Add(BitConverter.ToUInt32(miniFatBytes, i));
            _miniStream = ReadChain(_dir[0].Start, _dir[0].Size);
        }

        long SectorOffset(uint s) { return (long)(s + 1) * _sector; }

        byte[] ReadChain(uint start, long size)
        {
            var ms = new MemoryStream();
            uint s = start;
            int guard = 0;
            while (s != EndOfChain && s != FreeSect && s < _fat.Count + 1 && guard++ < 1000000)
            {
                long off = SectorOffset(s);
                if (off >= _f.Length) break;
                ms.Write(_f, (int)off, (int)Math.Min(_sector, _f.Length - off));
                if (s >= _fat.Count) break;
                s = _fat[(int)s];
            }
            byte[] all = ms.ToArray();
            if (size >= 0 && size < all.Length) Array.Resize(ref all, (int)size);
            return all;
        }

        public byte[] ReadStream(int index)
        {
            Entry e = _dir[index];
            if (e.Size >= _cutoff) return ReadChain(e.Start, e.Size);
            var ms = new MemoryStream();
            uint s = e.Start;
            int guard = 0;
            while (s != EndOfChain && s != FreeSect && s < _miniFat.Count && guard++ < 1000000)
            {
                int off = (int)s * _mini;
                if (off >= _miniStream.Length) break;
                ms.Write(_miniStream, off, Math.Min(_mini, _miniStream.Length - off));
                s = _miniFat[(int)s];
            }
            byte[] all = ms.ToArray();
            if (e.Size < all.Length) Array.Resize(ref all, (int)e.Size);
            return all;
        }

        // Child of a storage by name (names compare case-insensitively).
        public int FindChild(int storage, string name)
        {
            var stack = new Stack<int>();
            int root = _dir[storage].Child;
            if (root >= 0 && root < _dir.Count) stack.Push(root);
            int guard = 0;
            while (stack.Count > 0 && guard++ < 100000)
            {
                int i = stack.Pop();
                if (i < 0 || i >= _dir.Count) continue;
                Entry e = _dir[i];
                if (string.Equals(e.Name, name, StringComparison.OrdinalIgnoreCase)) return i;
                if (e.Left >= 0 && e.Left < _dir.Count) stack.Push(e.Left);
                if (e.Right >= 0 && e.Right < _dir.Count) stack.Push(e.Right);
            }
            return -1;
        }

        // A storage called storageName that holds streamName, anywhere.
        public int FindStorageWithStream(string storageName, string streamName)
        {
            for (int i = 0; i < _dir.Count; i++)
            {
                Entry e = _dir[i];
                if ((e.Type == 1 || e.Type == 5) &&
                    string.Equals(e.Name, storageName, StringComparison.OrdinalIgnoreCase) &&
                    FindChild(i, streamName) >= 0)
                    return i;
            }
            return -1;
        }
    }
}
