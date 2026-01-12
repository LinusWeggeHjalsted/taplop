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
            SoundControllerScript.Instance.PlayEquipWeaponSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));

            WeaponScript currentWeaponScript = currentItem.GetComponent<WeaponScript>();
            GameObject currentSecondSkill = currentWeaponScript.SecondSkill();
            Skill currentSecondSkillScript = currentSecondSkill.GetComponent<Skill>();
            string currentSecondSkillName = currentSecondSkillScript.GetSkillName();
            int currentSecondCooldown = playerScript.GetSkillCooldown(currentSecondSkillName);
            GameObject currentThirdSkill = currentWeaponScript.ThirdSkill();
            Skill currentThirdSkillScript = currentThirdSkill.GetComponent<Skill>();
            string currentThirdSkillName = currentThirdSkillScript.GetSkillName();
            int currentThirdCooldown = playerScript.GetSkillCooldown(currentThirdSkillName);
            
            WeaponScript selectedWeaponScript = selectedItem.GetComponent<WeaponScript>();
            GameObject selectedSecondSkill = selectedWeaponScript.SecondSkill();
            Skill selectedSecondSkillScript = selectedSecondSkill.GetComponent<Skill>();
            string selectedSecondSkillName = selectedSecondSkillScript.GetSkillName();
            int selectedSecondCooldown = playerScript.GetSkillCooldown(selectedSecondSkillName);
            GameObject selectedThirdSkill = selectedWeaponScript.ThirdSkill();
            Skill selectedThirdSkillScript = selectedThirdSkill.GetComponent<Skill>();
            string selectedThirdSkillName = selectedThirdSkillScript.GetSkillName();
            int selectedThirdCooldown = playerScript.GetSkillCooldown(selectedThirdSkillName);

            int maxSecondCooldown = Math.Max(currentSecondCooldown, selectedSecondCooldown);
            int maxThirdCooldown = Math.Max(currentThirdCooldown, selectedThirdCooldown);
            playerScript.SetSkillCooldown(selectedSecondSkillName, maxSecondCooldown);
            playerScript.SetSkillCooldown(selectedThirdSkillName, maxThirdCooldown);
        }
        else
        {
            SoundControllerScript.Instance.PlayEquipArmorSound(new Vector3(Screen.width / 2f, Screen.height / 2f, 0));
        }
        // refresh open menus
        Transform characterUI = GameObject.Find("Character UI").transform;
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
        GameObject skillsPanel = GameObject.Find("Skills Panel");
        SkillBarScript skillBarScript = skillsPanel.GetComponent<SkillBarScript>();
        skillBarScript.UpdateButtons();
        // refresh health bar in case max health changed
        GameObject playerHealthBar = GameObject.Find("Player Health Bar");
        PlayerHealthBarScript playerHealthBarScript = playerHealthBar.GetComponent<PlayerHealthBarScript>();
        playerHealthBarScript.UpdateHealthBar();
        // restart move step in case speed changed (only exists in missions, not hub)
        GameObject turnLogic = GameObject.Find("Turn Logic");
        if (turnLogic != null)
        {
            TurnLogicScript turnLogicScript = turnLogic.GetComponent<TurnLogicScript>();
            turnLogicScript.RestartPlayerMoveStep();
        }
        // close context menu
        Transform canvas = GameObject.Find("Canvas").transform;
        Transform contextMenu = canvas.Find("Context Menu");
        if (contextMenu != null)
        {
            Destroy(contextMenu.gameObject);
        }
    }

    void Start()
    {
        equipText = this.transform.Find("Equip Button Text").gameObject.GetComponent<TMP_Text>();
        player = GameObject.Find("Player");
        playerScript = player.GetComponent<PlayerCharacterScript>();
        button = this.GetComponent<Button>();
        button.onClick.AddListener(OnActivate);
    }
}
