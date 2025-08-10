## **Two RAIDZ2 Pools vs One RAIDZ3: Why I Chose Operational Sanity Over Storage Efficiency**


**Introduction**
Lately, I've been on a bit of a homelab kick, especially with all these new privacy laws (provide examples here). I wanted to take control of my digital life and experience and start self hosting everything I rely on (outside of Email/Password Managers - Bitwarden rules BTW).

Initially, starting with a 60TB RAIDz2 pool made sense, but over a couple years the utilization on that pool grew past 70% and I figured it was time to expand.
ZFS tends to slow down once more than 80% of the pool is utilized, due to it's nature as a CoW (copy on write) filesystem and the fragmentation that is incurred over time.

**The Hardware Reality Nobody Talks About**
When choosing how to expand, I briefly though about pulling a disk from my RAIDz2 pool, buying another 11 disks, and creating a RAIDz3 pool out of them which I was going to migrate to. That was until I realized my hardware reality: I only had 8 motherboard SATA ports, and my RAIDz3 pool would need to live partially in a USB enclosure. And there's a cardinal rule in storage: *never mix motherboard and enclosure drives in the same vdev*.

Why, you may ask? Let's say the 6 drive enclosure experiences a brief blip, just long enough for 4 disks to disconnect and reconnect. This would immediately result in a faulted RAIDz3 pool! Real hardware has real constraints - and that level of risk was not tenable to live with.

So I figured, why not build another RAIDZ2 vdev with all its drives inside the USB enclosure. I could have added a second RAIDZ2 vdev to my existing pool, but I decided to keep it as a totally separate pool instead. This way, if one pool has issues, I don't lose access to both. Plus, I can take one pool offline for maintenance without affecting the other.

But then that leads to all sorts of issues - how do apps know which pool to write to, how can both pools be treated as one in a seamless way?

The answer was MergerFS!

**Why Not Mirrors?**
[Some ZFS experts argue for using mirror vdevs instead of RAIDZ2](https://jrs-s.net/2015/02/06/zfs-you-should-use-mirror-vdevs-not-raidz/), citing faster resilver times and lower I/O load during rebuilds. They have a point - mirrors resilver much faster since you're only reading from one surviving disk instead of all surviving RAIDZ members. But I went with RAIDZ2 because I get 66% storage efficiency (4 data drives out of 6) versus 50% with mirrors (3 data drives out of 6). For my homelab budget, that extra storage capacity was worth the longer resilver times. Plus, RAIDZ2 can survive ANY two drive failures, while mirrors only survive specific failure combinations.

**MergerFS Integration**
MergerFS lets me present both pools as a single unified filesystem to applications. I can set policies for how data gets distributed - fill one pool first, spread evenly, or even direct specific types of data to specific pools. Apps see one big storage space, but I get the operational benefits of separate pools.

**Migration & Future Flexibility**
The two-pool approach also solved problems I didn't even know I had. Want to upgrade servers? I can migrate one 6-drive pool at a time instead of dealing with 12 drives all at once. Need to move to a server with fewer SATA ports? No problem - one pool can live on motherboard SATA, the other in an enclosure.
Most importantly, I can scale linearly - when I need another 60TB, I just buy a new enclosure and 6 more drives, add it to mergerfs, and I'm done. No infrastructure changes, no migration projects, no downtime.

**Resilver Time Reality Check / Why RAIDZ1 Was Never Considered**
There's also the rebuild anxiety factor that nobody talks about. My monthly scrubs take about 2 days, so a resilver would probably take 4-5 days - manageable and predictable. But imagine a 12-drive RAIDZ3 array: you're looking at a week or more of nail-biting while the array slowly rebuilds, during which time performance tanks and you're vulnerable to additional failures. The longer the resilver, the higher the chance of a second drive failing during the process. This is also why RAIDZ1 was never even considered - with 16TB drives, the probability of hitting an Unrecoverable Read Error during a rebuild is way too high. I prefer my rebuilds measured in days, not weeks, and I like sleeping at night without worrying about my data.

<TODO>
**Performance & Reliability Benefits**
**ZFS Performance Optimization**
**Economics: Refurbished Enterprise Drives**
**Long-term Scaling Strategy**
**RAIDZ2 Expansion: Why I Didn't Go That Route**
**Economic Trade-offs**
**Real-World Operational Benefits**
</TODO>

**Conclusion**
Sometimes operational simplicity beats theoretical efficiency. 
I chose a path that prioritizes long-term maintainability over maximum storage density. 
Two years later, I sleep well knowing my data is safe and my future self won't hate me for painting myself into a corner.



**Introduction**
- Starting point: Had 60TB RAIDZ2, needed to expand to ~120TB
- The "obvious" choice: migrate everything to 12x16TB RAIDZ3 pool
- Why I rejected conventional wisdom and went with 2x RAIDZ2 instead
- This is about real-world constraints vs theoretical optimization

**The Hardware Reality Nobody Talks About**
- My setup: Pool 1 on 6x motherboard SATA ports, Pool 2 in USB→SATA enclosure
- **Critical rule: Never mix motherboard + enclosure drives in same vdev**
- Single 12-drive RAIDZ3 would span both motherboard and enclosure
- USB enclosure failure/disconnect = entire 120TB pool dead
- Two separate pools = enclosure dies, lose 60TB not 120TB
- Real hardware has real constraints that theory ignores

**MergerFS Integration**
- Two pools present as unified storage to applications
- Flexible data placement policies (fill one first, spread evenly, etc.)
- Easy to rebalance data between pools when needed
- Can set different policies for different directory trees

**Migration & Future Flexibility**
- Moving 12x16TB drives between servers is a logistical nightmare
- Cable management hell, multiple trips, high chance of mistakes
- What if new server only has 8 SATA ports instead of 12?
- Two 6-drive pools = migrate one at a time, independently
- Can upgrade server hardware without massive storage migration project
- Future-proofing > immediate efficiency

**Resilver Time Reality Check**
- 6-drive RAIDZ2 resilver: manageable timeframe
- 12-drive RAIDZ3 resilver: literal days/weeks of nail-biting
- Longer resilver = higher chance of second drive failure
- Performance impact during resilver affects entire array
- "I prefer my rebuilds measured in hours, not days"

**Performance & Reliability Benefits**
- Two separate vdevs = better read/write parallelism than one wide vdev
- Blast radius containment: one pool failure ≠ total data loss
- Can take one pool offline for maintenance without killing all storage
- Mixed workloads can be distributed across pools

**Why RAIDZ1 Was Never Considered**
- 16TB drives + RAIDZ1 = playing URE lottery during rebuild
- Unrecoverable Read Error probability too high with massive drives
- "I like sleeping at night without worrying about my data"
- Enterprise drives help but don't eliminate the risk

**ZFS Performance Optimization**
- 10% space reservation on each pool to preserve CoW performance
- ZFS tanks when pools exceed 80-90% utilization
- Copy-on-write needs free space for efficient block allocation
- Two pools = easier to maintain healthy utilization ratios
- Can monitor and manage pool fullness independently

**Economics: Refurbished Enterprise Drives**
- Strategy: Exos drives from datacenter pulls/refurbs
- Enterprise reliability at homelab prices ($15-20/TB vs $25-30 new)
- Why consumer drives are false economy for always-on NAS workloads
- 5-year warranty on refurb enterprise > 2-year on new consumer

**Long-term Scaling Strategy**
- Annual drive rotation: replace oldest drive each year
- Retired drives accumulate into second "junk data" RAIDZ2 pool
- Want another 60TB? New enclosure + 6 drives + add to mergerfs
- No case limits, motherboard constraints, or infrastructure changes
- Linear scaling vs exponential complexity

**RAIDZ2 Expansion: Why I Didn't Go That Route**
- OpenZFS vdev expansion kills storage efficiency
- Adding drives to existing vdev = capacity limited by smallest drive size
- Creates uneven performance characteristics across the vdev
- "I'd rather pay more for clean, predictable pool geometry"

**Economic Trade-offs**
- Downside: Need $1400 chunks (6x drives) vs incremental expansion
- But: Better than $2800+ for complete 12-drive migration
- Can save up over time, buy during Black Friday/sales
- Bulk purchase actually enables better per-drive pricing

**Real-World Operational Benefits**
- Simpler troubleshooting: issues isolated to specific pools
- Easier capacity planning and monitoring
- More granular backup strategies possible
- Less vendor lock-in to specific hardware configurations

**Conclusion**
- Sometimes operational simplicity beats theoretical efficiency
- Real-world constraints matter more than spreadsheet optimization
- Built for 10-year operational timeline, not just initial deployment
- "Perfect is the enemy of good enough to sleep well at night"

---

This covers every angle and gives you a complete roadmap for a genuinely useful post that other homelab people will bookmark and reference.