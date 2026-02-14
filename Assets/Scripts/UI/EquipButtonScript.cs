using UnityEngine;
using UnityEngine.UI;
using TMPro;
using System;
using System.Collections;

public class EquipButtonScript : MonoBehaviour
{
    public GameObject player;
    public PlayerCharacterScript playerScript;
    public Button button;
    public TMP_Text equipText;
    public Transform targetTransform; // will be set from context menu
    public GameObject selectedItem; // will be set from context menu

    public IEnumerator SetText(string text)
    {
        while (equipText == null)
        {
            yield return null;
        }
        equipText.text = text;
    }

    public void OnActivate()
    {
        if (targetTransform == null || selectedItem == null)
        {
            Debug.LogError("targetTransform or selectedItem not set yet");
            return;
        }
        ItemScript selectedItemScript = selectedItem.GetComponent<ItemScript>();
        int selectedItemPosition = selectedItemScript.inventoryPosition;
        GameObject currentItem = null;
        int currentItemPosition = 0;
        if (targetTransform.childCount > 0)
        {
            currentItem = targetTransform.GetChild(0).gameObject;
            currentItem.transform.parent = playerScript.inventory;
        }
        selectedItem.transform.parent = targetTransform;
        // swap inventory positions
        ItemScript currentItemScript = null;
        if (currentItem != null)
        {
            currentItemScript = currentItem.gameObject.GetComponent<ItemScript>();
            currentItemPosition = currentItemScript.inventoryPosition;
            currentItemScript.inventoryPosition = selectedItemPosition;
        }
        selectedItemScript.inventoryPosition = currentItemPosition;
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
            
            WeaponScript selectedWeaponScript = selectedItem.GetComponent<WeaponScript>();
            GameObject selectedSecondSkill = selectedWeaponScript.SecondSkill();
            SkillScript selectedSecondSkillScript = selectedSecondSkill.GetComponent<SkillScript>();
            string selectedSecondSkillName = selectedSecondSkillScript.GetSkillName();
            int selectedSecondCooldown = playerScript.GetSkillCooldown(selectedSecondSkillName);
            GameObject selectedThirdSkill = selectedWeaponScript.ThirdSkill();
            SkillScript selectedThirdSkillScript = selectedThirdSkill.GetComponent<SkillScript>();
            string selectedThirdSkillName = selectedThirdSkillScript.GetSkillName();
            int selectedThirdCooldown = playerScript.GetSkillCooldown(selectedThirdSkillName);

            int maxSecondCooldown = Math.Max(currentSecondCooldown, selectedSecondCooldown);
            int maxThirdCooldown = Math.Max(currentThirdCooldown, selectedThirdCooldown);
            playerScript.SetSkillCooldown(selectedSecondSkillName, maxSecondCooldown);
            playerScript.SetSkillCooldown(selectedThirdSkillName, maxThirdCooldown);
        }
        else
        {
            SoundControllerScript.Instance.PlayEquipArmorSound();
        }
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
        // refresh skills panel in case weapons changed
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
        // close context menu
        Transform canvas = GameReferences.GetCanvasTransform();
        Transform contextMenu = canvas.Find("Context Menu");
        if (contextMenu != null)
        {
            Destroy(contextMenu.gameObject);
        }
    }

    void Awake()
    {
        equipText = this.transform.Find("Equip Button Text").gameObject.GetComponent<TMP_Text>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }

    void Start()
    {
        player = GameReferences.GetPlayer();
        playerScript = player.GetComponent<PlayerCharacterScript>();
    }
}
