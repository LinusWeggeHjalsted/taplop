using UnityEngine;
using UnityEngine.UI;
using UnityEngine.EventSystems;
using UnityEngine.InputSystem;
using System.Collections.Generic;

public class InventoryItemScript : MonoBehaviour, IBeginDragHandler, IDragHandler, IEndDragHandler, IPointerEnterHandler, IPointerExitHandler, IPointerClickHandler
{
    public GameObject item;
    public Transform currentParent;
    public Transform canvas;
    public GameObject inventoryMenu;
    public InventoryMenuScript inventoryMenuScript;
    public GameObject tooltipPrefab;
    public GameObject tooltip;
    public GameObject contextMenuPrefab;
    public GameObject contextMenu;
    public GameObject player;
    public PlayerCharacterScript playerScript;
    private float lastClickTime = 0f;
    private const float doubleClickThreshold = 0.3f;
    public string itemType
    {
        get
        {
            ItemScript itemScript = item.GetComponent<ItemScript>();
            return itemScript.ItemType();
        }
    }
    public int inventoryPosition
    {
        get
        {
            ItemScript itemScript = item.GetComponent<ItemScript>();
            return itemScript.inventoryPosition;
        }
    }

    public void OnBeginDrag(PointerEventData eventData)
    {
        if (inventoryMenu == null)
        {
            inventoryMenu = GameObject.Find("Inventory Menu(Clone)");
        }
        if (inventoryMenu != null)
        {
            inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
        }
        if (inventoryMenuScript != null)
        {
            Keyboard keyboard = Keyboard.current;
            if (keyboard == null)
            {
                inventoryMenuScript.isShiftDragging = false;
            }
            else
            {
                bool shiftPressed = keyboard.leftShiftKey.isPressed || keyboard.rightShiftKey.isPressed;
                if (shiftPressed)
                {
                    // set beginDragCornerIndex for multi-select salvage
                    ItemScript itemScript = item.GetComponent<ItemScript>();
                    inventoryMenuScript.isShiftDragging = true;
                    inventoryMenuScript.beginDragCornerIndex = itemScript.inventoryPosition;
                    return;
                }
                else
                {
                    inventoryMenuScript.isShiftDragging = false;
                }
            }
        }
        this.transform.parent = canvas;
        this.transform.SetAsLastSibling();
        Image itemImage = GetComponent<Image>();
        itemImage.raycastTarget = false;
    }

    public void OnDrag(PointerEventData eventData)
    {
        if (inventoryMenuScript != null && inventoryMenuScript.isShiftDragging)
        {
            // check if shift is still being held
            Keyboard keyboard = Keyboard.current;
            if (keyboard != null)
            {
                bool shiftPressed = keyboard.leftShiftKey.isPressed || keyboard.rightShiftKey.isPressed;
                if (!shiftPressed)
                {
                    inventoryMenuScript.endDragCornerIndex = 0;
                    return;
                }
            }
            // find the Item Slot under cursor
            List<RaycastResult> results = new List<RaycastResult>();
            EventSystem.current.RaycastAll(eventData, results);
            foreach (RaycastResult result in results)
            {
                ItemSlotScript itemSlot = result.gameObject.GetComponent<ItemSlotScript>();
                if (itemSlot != null)
                {
                    inventoryMenuScript.endDragCornerIndex = itemSlot.inventoryPosition;
                    break;
                }
            }
            return;
        }
        this.transform.position = eventData.position;
    }

    public void OnEndDrag(PointerEventData eventData)
    {
        if (inventoryMenuScript != null && inventoryMenuScript.isShiftDragging)
        {
            Keyboard keyboard = Keyboard.current;
            if (keyboard != null)
            {
                bool shiftPressed = keyboard.leftShiftKey.isPressed || keyboard.rightShiftKey.isPressed;
                if (shiftPressed)
                {
                    inventoryMenuScript.SalvageSelection();
                }
            }
            inventoryMenuScript.isShiftDragging = false;
            inventoryMenuScript.beginDragCornerIndex = 0;
            inventoryMenuScript.endDragCornerIndex = 0;
            return;
        }
        this.transform.parent = currentParent;
        this.transform.localPosition = new Vector3(0, 0, 0);
        Image itemImage = GetComponent<Image>();
        itemImage.raycastTarget = true;
    }

    public void OnPointerEnter(PointerEventData eventData)
    {
        if (item != null)
        {
            ItemScript itemScript = item.GetComponent<ItemScript>();
            string itemName = itemScript.ItemName();
            string itemDescription = itemScript.ItemDescription();
            RectTransform itemSlotRectTransform = currentParent.GetComponent<RectTransform>();
            Vector3[] itemCorners = new Vector3[4];
            itemSlotRectTransform.GetWorldCorners(itemCorners);
            Vector3 itemBottomRightPosition = itemCorners[3];

            Transform tooltipTransform = canvas.Find("Tooltip");
            if (tooltipTransform != null)
            {
                tooltip = tooltipTransform.gameObject;
            }
            if (tooltip == null)
            {
                tooltip = Instantiate(tooltipPrefab, canvas);
                tooltip.name = "Tooltip";
                tooltip.transform.SetAsLastSibling();
            }
            if (tooltip != null)
            {
                RectTransform tooltipRectTransform = tooltip.GetComponent<RectTransform>();
                tooltipRectTransform.pivot = new Vector2(0, 0);
                tooltipRectTransform.position = itemBottomRightPosition;
                TooltipScript tooltipScript = tooltip.GetComponent<TooltipScript>();
                StartCoroutine(tooltipScript.SetText(itemName, itemDescription));
                tooltip.SetActive(true);
            }
        }
    }

    public void OnPointerExit(PointerEventData eventData)
    {
        if (tooltip != null)
        {
            tooltip.SetActive(false);
        }
    }

    public void OnPointerClick(PointerEventData eventData)
    {
        if (item == null) return;

        Keyboard keyboard = Keyboard.current;
        if (keyboard == null) return;

        ItemScript itemScript = item.GetComponent<ItemScript>();
        bool isInInventory = item.transform.parent == playerScript.inventory;
        bool isDoubleClick = (Time.time - lastClickTime) < doubleClickThreshold;
        lastClickTime = Time.time;

        bool shiftPressed = keyboard.leftShiftKey.isPressed || keyboard.rightShiftKey.isPressed;
        bool ctrlPressed = keyboard.leftCtrlKey.isPressed || keyboard.rightCtrlKey.isPressed;
        bool altPressed = keyboard.leftAltKey.isPressed || keyboard.rightAltKey.isPressed;

        bool shiftOnly = shiftPressed && !ctrlPressed && !altPressed;
        bool ctrlOnly = ctrlPressed && !shiftPressed && !altPressed;
        bool altOnly = altPressed && !shiftPressed && !ctrlPressed;
        bool noModifiers = !shiftPressed && !ctrlPressed && !altPressed;

        if (eventData.button == PointerEventData.InputButton.Left)
        {
            // salvage materials from item
            if (isInInventory && (shiftOnly || SalvageToolButtonScript.Instance.salvageToolIsActive))
            {
                SalvageItem();
                return;
            }
            // equip item to mainhand (or learn if tome)
            if (ctrlOnly || isDoubleClick)
            {
                if (itemScript.ItemType() == "Tome")
                {
                    LearnTome();
                }
                else if (itemScript.ItemType() == "Weapon")
                {
                    EquipItem(playerScript.mainHand);
                }
                else
                {
                    EquipItemToDefaultSlot();
                }
                return;
            }
            // equip weapon to offhand
            if (altOnly && itemScript.ItemType() == "Weapon")
            {
                EquipItem(playerScript.offHand);
                return;
            }
        }

        if (eventData.button == PointerEventData.InputButton.Right)
        {
            // equip weapon to offhand (or default slot for non-weapons)
            if (ctrlOnly || isDoubleClick)
            {
                if (itemScript.ItemType() == "Weapon")
                {
                    EquipItem(playerScript.offHand);
                }
                else
                {
                    EquipItemToDefaultSlot();
                }
                return;
            }
            // equip weapon to mainhand
            if (altOnly && itemScript.ItemType() == "Weapon")
            {
                EquipItem(playerScript.mainHand);
                return;
            }
        }
    }

    private void SalvageItem()
    {
        ItemScript itemScript = item.GetComponent<ItemScript>();
        PlayerDataScript.Salvage salvageValue = itemScript.SalvageValue();
        SoundControllerScript.Instance.PlaySalvageSound();
        PlayerDataScript.Instance.collectedSalvage += salvageValue;
        DestroyImmediate(item);
        RefreshUI();
    }

    private void LearnTome()
    {
        SkillTomeScript tomeScript = item.GetComponent<SkillTomeScript>();
        string skillName = tomeScript.skillName;
        PlayerDataScript playerDataScript = PlayerDataScript.Instance;
        if (playerDataScript.unlockedSkills.Contains(skillName))
        {
            // skill already learned, do nothing
        }
        else
        {
            SoundControllerScript.Instance.PlayLearnSkillSound();
            playerDataScript.unlockedSkills.Add(skillName);
            DestroyImmediate(item);
            RefreshUI();
        }
    }

    private void EquipItem(Transform targetTransform)
    {
        ItemScript selectedItemScript = item.GetComponent<ItemScript>();
        bool isSelectedItemEquipped = item.transform.parent != playerScript.inventory;
        int selectedItemPosition = selectedItemScript.inventoryPosition;
        GameObject currentItem = null;
        int currentItemPosition = 0;
        ItemScript currentItemScript = null;

        if (targetTransform.childCount > 0)
        {
            currentItem = targetTransform.GetChild(0).gameObject;
            currentItemScript = currentItem.GetComponent<ItemScript>();
        }

        // if swapping between two equipped slots, just swap parents directly
        if (isSelectedItemEquipped && currentItem != null)
        {
            Transform selectedItemOldParent = item.transform.parent;
            currentItem.transform.parent = selectedItemOldParent;
            item.transform.parent = targetTransform;
        }
        // if equipping from inventory to gear slot
        else
        {
            if (currentItem != null)
            {
                currentItem.transform.parent = playerScript.inventory;
            }
            item.transform.parent = targetTransform;
            // swap inventory positions
            if (currentItem != null)
            {
                currentItemPosition = currentItemScript.inventoryPosition;
                currentItemScript.inventoryPosition = selectedItemPosition;
            }
            selectedItemScript.inventoryPosition = currentItemPosition;
        }
        // set new skill cooldowns to max of the swapped skills in case a weapon was equipped
        if (selectedItemScript.ItemType() == "Weapon" && currentItemScript != null)
        {
            SoundControllerScript.Instance.PlayEquipWeaponSound();

            WeaponScript currentWeaponScript = currentItem.GetComponent<WeaponScript>();
            GameObject currentSecondSkill = currentWeaponScript.SecondSkill();
            SkillScript currentSecondSkillScript = currentSecondSkill.GetComponent<SkillScript>();
            string currentSecondSkillName = currentSecondSkillScript.GetSkillName();
            int currentSecondCooldown = playerScript.GetSkillCooldown(currentSecondSkillName);
            GameObject currentThirdSkill = currentWeaponScript.ThirdSkill();
            SkillScript currentThirdSkillScript = currentThirdSkill.GetComponent<SkillScript>();
            string currentThirdSkillName = currentThirdSkillScript.GetSkillName();
            int currentThirdCooldown = playerScript.GetSkillCooldown(currentThirdSkillName);

            WeaponScript selectedWeaponScript = item.GetComponent<WeaponScript>();
            GameObject selectedSecondSkill = selectedWeaponScript.SecondSkill();
            SkillScript selectedSecondSkillScript = selectedSecondSkill.GetComponent<SkillScript>();
            string selectedSecondSkillName = selectedSecondSkillScript.GetSkillName();
            int selectedSecondCooldown = playerScript.GetSkillCooldown(selectedSecondSkillName);
            GameObject selectedThirdSkill = selectedWeaponScript.ThirdSkill();
            SkillScript selectedThirdSkillScript = selectedThirdSkill.GetComponent<SkillScript>();
            string selectedThirdSkillName = selectedThirdSkillScript.GetSkillName();
            int selectedThirdCooldown = playerScript.GetSkillCooldown(selectedThirdSkillName);

            int maxSecondCooldown = System.Math.Max(currentSecondCooldown, selectedSecondCooldown);
            int maxThirdCooldown = System.Math.Max(currentThirdCooldown, selectedThirdCooldown);
            playerScript.SetSkillCooldown(selectedSecondSkillName, maxSecondCooldown);
            playerScript.SetSkillCooldown(selectedThirdSkillName, maxThirdCooldown);

            if (currentItem.transform.parent != playerScript.inventory)
            {
                playerScript.SetSkillCooldown(currentSecondSkillName, maxSecondCooldown);
                playerScript.SetSkillCooldown(currentThirdSkillName, maxThirdCooldown);
            }
        }
        else
        {
            SoundControllerScript.Instance.PlayEquipArmorSound();
        }
        RefreshUI();
    }

    private void EquipItemToDefaultSlot()
    {
        ItemScript itemScript = item.GetComponent<ItemScript>();
        string itemType = itemScript.ItemType();
        Transform targetTransform = null;

        if (itemType == "Weapon")
        {
            targetTransform = playerScript.mainHand;
        }
        else if (itemType == "Amulet")
        {
            targetTransform = playerScript.neck;
        }
        else if (itemType == "Coat")
        {
            targetTransform = playerScript.body;
        }
        else if (itemType == "Gloves")
        {
            targetTransform = playerScript.hands;
        }
        else if (itemType == "Pants")
        {
            targetTransform = playerScript.legs;
        }
        else if (itemType == "Boots")
        {
            targetTransform = playerScript.feet;
        }

        if (targetTransform != null)
        {
            EquipItem(targetTransform);
        }
    }

    private void RefreshUI()
    {
        // refresh open menus
        Transform characterUI = GameReferences.GetCharacterUI().transform;
        Transform gearMenu = characterUI.Find("Gear Menu(Clone)");
        if (gearMenu != null)
        {
            GearMenuScript gearMenuScript = gearMenu.GetComponent<GearMenuScript>();
            gearMenuScript.RefreshUI();
        }
        Transform inventoryMenu = characterUI.Find("Inventory Menu(Clone)");
        if (inventoryMenu != null)
        {
            InventoryMenuScript inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
            inventoryMenuScript.RefreshUI();
        }
        Transform skillsMenu = characterUI.Find("Skills Menu(Clone)");
        if (skillsMenu != null)
        {
            SkillsMenuScript skillsMenuScript = skillsMenu.GetComponent<SkillsMenuScript>();
            skillsMenuScript.RefreshUI();
        }
        // refresh skillbar in case weapons changed
        GameObject skillsPanel = GameReferences.GetSkillsPanel();
        SkillBarScript skillBarScript = skillsPanel.GetComponent<SkillBarScript>();
        playerScript.UpdateEquippedSkills();
        skillBarScript.UpdateButtons();
        // refresh health bar in case max health changed
        GameObject playerHealthBar = GameReferences.GetPlayerHealthBar();
        PlayerHealthBarScript playerHealthBarScript = playerHealthBar.GetComponent<PlayerHealthBarScript>();
        playerHealthBarScript.UpdateHealthBar();
        // restart move step in case speed changed (only exists in missions, not hub)
        GameObject turnLogic = GameReferences.GetTurnLogic();
        if (turnLogic != null)
        {
            TurnLogicScript turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
            turnLogicScript.RestartPlayerMoveStep();
        }
    }

    void Awake()
    {
        currentParent = this.transform.parent;
        tooltipPrefab = Resources.Load<GameObject>("Prefabs/UI/Tooltip");
        contextMenuPrefab = Resources.Load<GameObject>("Prefabs/UI/Context Menu");
    }

    void Start()
    {
        canvas = GameReferences.GetCanvasTransform();
        inventoryMenu = GameObject.Find("Inventory Menu(Clone)");
        if (inventoryMenu != null)
        {
            inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
        }
        player = GameReferences.GetPlayer();
        playerScript = player.GetComponent<PlayerCharacterScript>();
    }

    void OnDestroy()
    {
        if (tooltip != null)
        {
            Destroy(tooltip);
        }
        if (contextMenu != null)
        {
            Destroy(contextMenu);
        }
    }
}
