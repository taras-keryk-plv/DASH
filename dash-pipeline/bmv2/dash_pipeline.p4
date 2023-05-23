#include <core.p4>
#include "dash_arch_specific.p4"

#include "dash_headers.p4"
#include "dash_metadata.p4"
#include "dash_parser.p4"
#include "dash_vxlan.p4"
#include "dash_nvgre.p4"
#include "dash_outbound.p4"
#include "dash_inbound.p4"
#include "dash_conntrack.p4"

control dash_ingress(
      inout headers_t hdr
    , inout metadata_t meta
#ifdef TARGET_BMV2_V1MODEL
    , inout standard_metadata_t standard_metadata
#endif // TARGET_BMV2_V1MODEL
#ifdef TARGET_DPDK_PNA
    , in    pna_main_input_metadata_t  istd
    , inout pna_main_output_metadata_t ostd
#endif // TARGET_DPDK_PNA
    )
{
    action drop_action() {
#ifdef TARGET_BMV2_V1MODEL
        mark_to_drop(standard_metadata);
#endif // TARGET_BMV2_V1MODEL
#ifdef TARGET_DPDK_PNA
        drop_packet();
#endif // TARGET_DPDK_PNA
    }

    action deny() {
        meta.dropped = true;
    }

    action accept() {
    }

    @name("vip|dash_vip")
    table vip {
        key = {
            hdr.ipv4.dst_addr : exact @name("hdr.ipv4.dst_addr:VIP");
        }

        actions = {
            accept;
            @defaultonly deny;
        }

        const default_action = deny;
    }

    action set_outbound_direction() {
        meta.direction = dash_direction_t.OUTBOUND;
    }

    action set_inbound_direction() {
        meta.direction = dash_direction_t.INBOUND;
    }

    @name("direction_lookup|dash_direction_lookup")
    table direction_lookup {
        key = {
            hdr.vxlan.vni : exact @name("hdr.vxlan.vni:VNI");
        }

        actions = {
            set_outbound_direction;
            @defaultonly set_inbound_direction;
        }

        const default_action = set_inbound_direction;
    }

    action set_appliance(EthernetAddress neighbor_mac,
                         EthernetAddress mac) {
        meta.encap_data.underlay_dmac = neighbor_mac;
        meta.encap_data.underlay_smac = mac;
    }

    /* This table API should be implemented manually using underlay SAI */
    table appliance {
        key = {
            meta.appliance_id : ternary @name("meta.appliance_id:appliance_id");
        }

        actions = {
            set_appliance;
        }
    }

#define ACL_GROUPS_PARAM(prefix) \
    bit<16> ## prefix ##_stage1_dash_acl_group_id, \
    bit<16> ## prefix ##_stage2_dash_acl_group_id, \
    bit<16> ## prefix ##_stage3_dash_acl_group_id, \
    bit<16> ## prefix ##_stage4_dash_acl_group_id, \
    bit<16> ## prefix ##_stage5_dash_acl_group_id

#define ACL_GROUPS_COPY_TO_META(prefix) \
   meta.stage1_dash_acl_group_id = ## prefix ##_stage1_dash_acl_group_id; \
   meta.stage2_dash_acl_group_id = ## prefix ##_stage2_dash_acl_group_id; \
   meta.stage3_dash_acl_group_id = ## prefix ##_stage3_dash_acl_group_id; \
   meta.stage4_dash_acl_group_id = ## prefix ##_stage4_dash_acl_group_id; \
   meta.stage5_dash_acl_group_id = ## prefix ##_stage5_dash_acl_group_id;

    action set_eni_attrs(bit<32> cps,
                         bit<32> pps,
                         bit<32> flows,
                         bit<1> admin_state,
                         IPv4Address vm_underlay_dip,
                         @Sai[type="sai_uint32_t"]
                         bit<24> vm_vni,
                         bit<16> vnet_id,
                         bit<16> v4_meter_policy_id,
                         bit<16> v6_meter_policy_id,
                         ACL_GROUPS_PARAM(inbound_v4),
                         ACL_GROUPS_PARAM(inbound_v6),
                         ACL_GROUPS_PARAM(outbound_v4),
                         ACL_GROUPS_PARAM(outbound_v6)) {
        meta.eni_data.cps            = cps;
        meta.eni_data.pps            = pps;
        meta.eni_data.flows          = flows;
        meta.eni_data.admin_state    = admin_state;
        meta.encap_data.underlay_dip = vm_underlay_dip;
        /* vm_vni is the encap VNI used for tunnel between inbound DPU -> VM
         * and not a VNET identifier */
        meta.encap_data.vni          = vm_vni;
        meta.vnet_id                 = vnet_id;

        if (meta.is_overlay_ip_v6 == 1) {
            if (meta.direction == dash_direction_t.OUTBOUND) {
                ACL_GROUPS_COPY_TO_META(outbound_v6);
            } else {
                ACL_GROUPS_COPY_TO_META(inbound_v6);
            }
            meta.meter_policy_id = v6_meter_policy_id;
        } else {
            if (meta.direction == dash_direction_t.OUTBOUND) {
                ACL_GROUPS_COPY_TO_META(outbound_v4);
            } else {
                ACL_GROUPS_COPY_TO_META(inbound_v4);
            }
            meta.meter_policy_id = v4_meter_policy_id;
        }
    }

    @name("eni|dash_eni")
    table eni {
        key = {
            meta.eni_id : exact @name("meta.eni_id:eni_id");
        }

        actions = {
            set_eni_attrs;
            @defaultonly deny;
        }
        const default_action = deny;
    }

#ifdef TARGET_BMV2_V1MODEL
    direct_counter(CounterType.packets_and_bytes) eni_counter;
#endif // TARGET_BMV2_V1MODEL
#ifdef TARGET_DPDK_PNA
#ifdef DPDK_SUPPORTS_DIRECT_COUNTER_ON_WILDCARD_KEY_TABLE
    // Omit all direct counters for tables with ternary match keys,
    // because the latest version of p4c-dpdk as of 2023-Jan-26 does
    // not support this combination of features.  If you try to
    // compile it with this code enabled, the error message looks like
    // this:
    //
    // [--Werror=target-error] error: Direct counters and direct meters are unsupported for wildcard match table outbound_acl_stage1:dash_acl_rule|dash_acl
    //
    // This p4c issue is tracking this feature gap in p4c-dpdk:
    // https://github.com/p4lang/p4c/issues/3868
    DirectCounter<bit<64>>(PNA_CounterType_t.PACKETS_AND_BYTES) eni_counter;
#endif // DPDK_SUPPORTS_DIRECT_COUNTER_ON_WILDCARD_KEY_TABLE
#endif // TARGET_DPDK_PNA

    table eni_meter {
        key = {
            meta.eni_id : exact @name("meta.eni_id:eni_id");
            meta.direction : exact @name("meta.direction:direction");
            meta.dropped : exact @name("meta.dropped:dropped");
        }

        actions = { NoAction; }

#ifdef TARGET_BMV2_V1MODEL
        counters = eni_counter;
#endif // TARGET_BMV2_V1MODEL
#ifdef TARGET_DPDK_PNA
#ifdef DPDK_SUPPORTS_DIRECT_COUNTER_ON_WILDCARD_KEY_TABLE
        pna_direct_counter = eni_counter;
#endif // DPDK_SUPPORTS_DIRECT_COUNTER_ON_WILDCARD_KEY_TABLE
#endif // TARGET_DPDK_PNA
    }

    action permit() {
    }

    action vxlan_decap_pa_validate(bit<16> src_vnet_id) {
        meta.vnet_id = src_vnet_id;
    }

    @name("pa_validation|dash_pa_validation")
    table pa_validation {
        key = {
            meta.vnet_id: exact @name("meta.vnet_id:vnet_id");
            hdr.ipv4.src_addr : exact @name("hdr.ipv4.src_addr:sip");
        }

        actions = {
            permit;
            @defaultonly deny;
        }

        const default_action = deny;
    }

    @name("inbound_routing|dash_inbound_routing")
    table inbound_routing {
        key = {
            meta.eni_id: exact @name("meta.eni_id:eni_id");
            hdr.vxlan.vni : exact @name("hdr.vxlan.vni:VNI");
            hdr.ipv4.src_addr : ternary @name("hdr.ipv4.src_addr:sip");
        }
        actions = {
            vxlan_decap(hdr);
            vxlan_decap_pa_validate;
            @defaultonly deny;
        }

        const default_action = deny;
    }

    action check_ip_addr_family(@Sai[type="sai_ip_addr_family_t", isresourcetype="true"] bit<32> ip_addr_family) {
        if (ip_addr_family == 0) /* SAI_IP_ADDR_FAMILY_IPV4 */ {
            if (meta.is_overlay_ip_v6 == 1) {
                meta.dropped = true;
            }
        } else {
            if (meta.is_overlay_ip_v6 == 0) {
                meta.dropped = true;
            }
        }
    }

    @name("meter_policy|dash_meter")
    @Sai[isobject="true"]
    table meter_policy {
        key = {
            meta.meter_policy_id : exact @name("meta.meter_policy_id:meter_policy_id");
        }
        actions = {
            check_ip_addr_family;
        }
    }

    action set_meter_class(bit<16> meter_class) {
        meta.policy_meter_class = meter_class;
    }

    @name("meter_rule|dash_meter")
    @Sai[isobject="true"]
    table meter_rule {
        key = {
            meta.meter_policy_id: exact @name("meta.meter_policy_id:meter_policy_id") @Sai[type="sai_object_id_t", isresourcetype="true", objects="METER_POLICY"];
            hdr.ipv4.dst_addr : ternary @name("hdr.ipv4.dst_addr:dip");
        }

     actions = {
            set_meter_class;
            @defaultonly NoAction;
        }
        const default_action = NoAction();
    }
    
    // MAX_METER_BUCKET = MAX_ENI(64) * NUM_BUCKETS_PER_ENI(4096)
    #define MAX_METER_BUCKETS 262144
#ifdef TARGET_BMV2_V1MODEL
    counter(MAX_METER_BUCKETS, CounterType.bytes) meter_bucket_inbound;
    counter(MAX_METER_BUCKETS, CounterType.bytes) meter_bucket_outbound;
#endif // TARGET_BMV2_V1MODEL
    action meter_bucket_action(
            @Sai[type="sai_uint64_t", isreadonly="true"] bit<64> outbound_bytes_counter,
            @Sai[type="sai_uint64_t", isreadonly="true"] bit<64> inbound_bytes_counter,
            @Sai[type="sai_uint32_t", skipattr="true"] bit<32> meter_bucket_index) {
        // read only counters for SAI api generation only
        meta.meter_bucket_index = meter_bucket_index;
    }

    @name("meter_bucket|dash_meter")
    @Sai[isobject="true"]
    table meter_bucket {
        key = {
            meta.eni_id: exact @name("meta.eni_id:eni_id");
            meta.meter_class: exact @name("meta.meter_class:meter_class");
        }
        actions = {
            meter_bucket_action;
            @defaultonly NoAction;
        }
        const default_action = NoAction();
    }

    action set_eni(bit<16> eni_id) {
        meta.eni_id = eni_id;
    }

    @name("eni_ether_address_map|dash_eni")
    table eni_ether_address_map {
        key = {
            meta.eni_addr : exact @name("meta.eni_addr:address");
        }

        actions = {
            set_eni;
            @defaultonly deny;
        }
        const default_action = deny;
    }

    action set_acl_group_attrs(@Sai[type="sai_ip_addr_family_t", isresourcetype="true"] bit<32> ip_addr_family) {
        if (ip_addr_family == 0) /* SAI_IP_ADDR_FAMILY_IPV4 */ {
            if (meta.is_overlay_ip_v6 == 1) {
                meta.dropped = true;
            }
        } else {
            if (meta.is_overlay_ip_v6 == 0) {
                meta.dropped = true;
            }
        }
    }

    @name("dash_acl_group|dash_acl")
    table acl_group {
        key = {
            meta.stage1_dash_acl_group_id : exact @name("meta.stage1_dash_acl_group_id:dash_acl_group_id");
        }
        actions = {
            set_acl_group_attrs();
        }
    }

    action set_src_tag(tag_map_t tag_map) {
        meta.src_tag_map = tag_map;
    }

    @name("src_tag|dash_tag")
    table src_tag {
        key = {
            meta.src_ip_addr : lpm @name("meta.src_ip_addr:sip");
        }
        actions = {
            set_src_tag;
        }
    }

    action set_dst_tag(tag_map_t tag_map) {
        meta.dst_tag_map = tag_map;
    }

    @name("dst_tag|dash_tag")
    table dst_tag {
        key = {
            meta.dst_ip_addr : lpm @name("meta.dst_ip_addr:dip");
        }
        actions = {
            set_dst_tag;
        }
    }

    apply {

        /* Send packet on same port it arrived (echo) by default */
#ifdef TARGET_BMV2_V1MODEL
        standard_metadata.egress_spec = standard_metadata.ingress_port;
#endif // TARGET_BMV2_V1MODEL
#ifdef TARGET_DPDK_PNA
#ifdef DPDK_PNA_SEND_TO_PORT_FIX_MERGED
        // As of 2023-Jan-26, the version of the pna.p4 header file
        // included with p4c defines send_to_port with a parameter
        // that has no 'in' direction.  The following commit in the
        // public pna repo fixes this, but this fix has not yet been
        // copied into the p4c repo.
        // https://github.com/p4lang/pna/commit/b9fdfb888e5385472c34ff773914c72b78b63058
        // Until p4c is updated with this fix, the following line will
        // give a compile-time error.
        send_to_port(istd.input_port);
#endif  // DPDK_PNA_SEND_TO_PORT_FIX_MERGED
#endif // TARGET_DPDK_PNA

        if (vip.apply().hit) {
            /* Use the same VIP that was in packet's destination if it's
               present in the VIP table */
            meta.encap_data.underlay_sip = hdr.ipv4.dst_addr;
        }

        /* If Outer VNI matches with a reserved VNI, then the direction is Outbound - */
        direction_lookup.apply();

        appliance.apply();

        /* Outer header processing */

        if (meta.direction == dash_direction_t.OUTBOUND) {
            vxlan_decap(hdr);
        } else if (meta.direction == dash_direction_t.INBOUND) {
            switch (inbound_routing.apply().action_run) {
                vxlan_decap_pa_validate: {
                    pa_validation.apply();
                    vxlan_decap(hdr);
                }
            }
        }

        meta.is_overlay_ip_v6 = 0;
        meta.ip_protocol = 0;
        meta.dst_ip_addr = 0;
        meta.src_ip_addr = 0;
        if (hdr.ipv6.isValid()) {
            meta.ip_protocol = hdr.ipv6.next_header;
            meta.src_ip_addr = hdr.ipv6.src_addr;
            meta.dst_ip_addr = hdr.ipv6.dst_addr;
            meta.is_overlay_ip_v6 = 1;
        } else if (hdr.ipv4.isValid()) {
            meta.ip_protocol = hdr.ipv4.protocol;
            meta.src_ip_addr = (bit<128>)hdr.ipv4.src_addr;
            meta.dst_ip_addr = (bit<128>)hdr.ipv4.dst_addr;
        }

        if (hdr.tcp.isValid()) {
            meta.src_l4_port = hdr.tcp.src_port;
            meta.dst_l4_port = hdr.tcp.dst_port;
        } else if (hdr.udp.isValid()) {
            meta.src_l4_port = hdr.udp.src_port;
            meta.dst_l4_port = hdr.udp.dst_port;
        }

        /* At this point the processing is done on customer headers */

        /* Put VM's MAC in the direction agnostic metadata field */
        meta.eni_addr = meta.direction == dash_direction_t.OUTBOUND  ?
                                          hdr.ethernet.src_addr :
                                          hdr.ethernet.dst_addr;
        eni_ether_address_map.apply();
        eni.apply();
        if (meta.eni_data.admin_state == 0) {
            deny();
        }
        acl_group.apply();

        src_tag.apply();
        dst_tag.apply();


        if (meta.direction == dash_direction_t.OUTBOUND) {
            outbound.apply(hdr, meta);
        } else if (meta.direction == dash_direction_t.INBOUND) {
            inbound.apply(hdr, meta);
        }

        if (meta.meter_policy_en == 1) {
            meter_policy.apply();
            meter_rule.apply();
        }

        {
            if (meta.meter_policy_en == 1) {
                meta.meter_class = meta.policy_meter_class;
            } else {
                meta.meter_class = meta.route_meter_class;
            }
            if ((meta.meter_class == 0) || (meta.mapping_meter_class_override == 1)) {
                meta.meter_class = meta.mapping_meter_class;
            }
        }

        meter_bucket.apply();
        if (meta.direction == dash_direction_t.OUTBOUND) {
#ifdef TARGET_BMV2_V1MODEL
            meter_bucket_outbound.count(meta.meter_bucket_index);
#endif
        } else if (meta.direction == dash_direction_t.INBOUND) {
#ifdef TARGET_BMV2_V1MODEL
            meter_bucket_inbound.count(meta.meter_bucket_index);
#endif
        }

        eni_meter.apply();

        if (meta.dropped) {
            drop_action();
        }
    }
}

#ifdef TARGET_BMV2_V1MODEL
#include "dash_bmv2_v1model.p4"
#endif // TARGET_BMV2_V1MODEL
#ifdef TARGET_DPDK_PNA
#include "dash_dpdk_pna.p4"
#endif // TARGET_DPDK_PNA
