# Managed by vmware-ubuntu-bootstrap.
patch:
  "schema_list":
    - schema: rime_ice

  "menu/page_size": 9

  "key_binder/bindings/+":
    - { when: paging, accept: minus, send: Page_Up }
    - { when: has_menu, accept: equal, send: Page_Down }
