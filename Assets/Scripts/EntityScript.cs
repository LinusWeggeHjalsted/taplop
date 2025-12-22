using UnityEngine;
using TMPro;
using System.Collections;
using System.Collections.Generic;
using System.Linq;

public class EntityScript : MonoBehaviour, PlayerCharacterScript
{
    private bool _finishedBuilding = false;
    public bool finishedBuilding
    {
        get
        {
            return _finishedBuilding;
        }
        set
        {
            _finishedBuilding = value;
        }
    }
    public GameObject levelBuilder;
    public LevelBuilderScript levelBuilderScript;
    public bool levelBuilderLoaded = false;
    public GameObject traversableTiles;
    public TraversableTilesScript traversableTilesScript;
    public GameObject player;
    public GameObject enemies;
    public EnemiesScript enemiesScript;
    public GameObject drops;
    public DropsScript dropsScript;
    public GameObject spriteObject;
    public SpriteRenderer spriteRenderer;
    private Sprite[] spriteSheet = new Sprite[2];
    public Sprite[] SpriteSheet
    {
        get
        {
            return spriteSheet;
        }
        set
        {
            // update SpriteRenderer
            spriteSheet = value;
            spriteRenderer.sprite = spriteSheet[0];
        }
    }
    public GameObject gear;
    public GearScript gearScript;

    private Transform _mainHand;
    private Transform _offHand;
    private Transform _neck;
    private Transform _body;
    private Transform _hands;
    private Transform _legs;
    private Transform _feet;
    private Transform _inventory;
    private int _inventorySize;
    private Transform _utilitySkills;
    private int _utilitySkillSlots;

    public Transform mainHand { get { return _mainHand; } }
    public Transform offHand { get { return _offHand; } }
    public Transform neck { get { return _neck; } }
    public Transform body { get { return _body; } }
    public Transform hands { get { return _hands; } }
    public Transform legs { get { return _legs; } }
    public Transform feet { get { return _feet; } }
    public Transform inventory { get { return _inventory; } }
    public int inventorySize { get { return _inventorySize; } }
    public Transform utilitySkills { get { return _utilitySkills; } }
    public int utilitySkillSlots 
    {
        get
        {
            return _utilitySkillSlots;
        }
        set
        {
            _utilitySkillSlots = value;
        }
    }

    public GameObject mainHandWeapon
    {
        get
        {
            if (mainHand.childCount == 0) return null;
            return mainHand.GetChild(0).gameObject;
        }
    }
    public GameObject offHandWeapon
    {
        get
        {
            if (offHand.childCount == 0) return null;
            return offHand.GetChild(0).gameObject;
        }
    }
    public GameObject amulet
    {
        get
        {
            if (neck.childCount == 0) return null;
            return neck.GetChild(0).gameObject;
        }
    }
    public GameObject coat
    {
        get
        {
            if (body.childCount == 0) return null;
            return body.GetChild(0).gameObject;
        }
    }
    public GameObject gloves
    {
        get
        {
            if (hands.childCount == 0) return null;
            return hands.GetChild(0).gameObject;
        }
    }
    public GameObject pants
    {
        get
        {
            if (legs.childCount == 0) return null;
            return legs.GetChild(0).gameObject;
        }
    }
    public GameObject boots
    {
        get
        {
            if (feet.childCount == 0) return null;
            return feet.GetChild(0).gameObject;
        }
    }
    public GameObject[] inventoryItems
    {
        get
        {
            GameObject[] itemArray = new GameObject[inventorySize];
            for (int i = 0; i < inventory.childCount; i++)
            {
                GameObject item = inventory.GetChild(i).gameObject;
                ItemScript itemScript = item.GetComponent<ItemScript>();
                int inventoryIndex = itemScript.inventoryPosition - 1; // 1-indexed inventoryPosition
                if (inventoryIndex < inventorySize)
                {
                    if (itemArray[inventoryIndex] != null)
                    {
                        Debug.LogError("item is occupying same slot as another item");
                    }
                    itemArray[inventoryIndex] = inventory.GetChild(i).gameObject;
                }
                else
                {
                    Debug.LogError("entity has more items in inventory than inventorySize " + inventorySize.ToString() + " allows");
                }
            }
            return itemArray;
        }
    }
    public GameObject healthBar;
    public SpriteRenderer healthBarRenderer;
    public Sprite[] healthBarStates = new Sprite[8];
    public Sprite hitSprite;
    public Sprite aggroSprite;
    public Sprite stunSprite;
    public Sprite reflectSprite;
    public Sprite[] enchantmentSprites = new Sprite[5];
    public GameObject displayedEnchantments;
    public SpriteRenderer enchantmentRenderer;

    public string currentBuildTemplate = "00000000";
    private int maxHealth;
    public int MaxHealth
    {
        get
        {
            int coatHealth = 0;
            if (coat != null)
            {
                CoatScript coatScript = coat.GetComponent<CoatScript>();
                coatHealth = coatScript.healthBonus;
            }
            return maxHealth + coatHealth;
        }
        set
        {
            maxHealth = value;
        }
    }
    private int currentHealth;
    public int CurrentHealth
    {
        get
        {
            return currentHealth;
        }
        set
        {
            if (value > MaxHealth)
            {
                currentHealth = MaxHealth;
            }
            else
            {
                currentHealth = value;
            }
            DisplayHealth();
            if (this.gameObject == player)
            {
                GameObject playerHealthBar = GameObject.Find("Player Health Bar");
                PlayerHealthBarScript playerHealthBarScript = playerHealthBar.GetComponent<PlayerHealthBarScript>();
                playerHealthBarScript.UpdateHealthBar();
            }
        }
    }
    private int armor;
    public int Armor
    {
        get
        {
            int coatArmor = 0;
            if (coat != null)
            {
                CoatScript coatScript = coat.GetComponent<CoatScript>();
                coatArmor = coatScript.armorBonus;
            }
            int glovesArmor = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesArmor = glovesScript.armorBonus;
            }
            int pantsArmor = 0;
            if (pants != null)
            {
                PantsScript pantsScript = pants.GetComponent<PantsScript>();
                pantsArmor = pantsScript.armorBonus;
            }
            int bootsArmor = 0;
            if (boots != null)
            {
                BootsScript bootsScript = boots.GetComponent<BootsScript>();
                bootsArmor = bootsScript.armorBonus;
            }
            return armor + coatArmor + glovesArmor + pantsArmor + bootsArmor;
        }
        set
        {
            armor = value;
        }
    }
    private int speed = 1;
    public int Speed
    {
        get
        {
            int bootsSpeed = 0;
            if (boots != null)
            {
                BootsScript bootsScript = boots.GetComponent<BootsScript>();
                bootsSpeed = bootsScript.speedBonus;
            }
            int effectiveSpeed = speed + bootsSpeed + enchantmentModifiers.speed;
            return effectiveSpeed;
        }
        set
        {
            speed = value;
        }
    }
    public int mainHandDamage
    {
        get
        {
            int mainHandWeaponDamage = 0;
            if (mainHandWeapon != null)
            {
                WeaponScript mainHandWeaponScript = mainHandWeapon.GetComponent<WeaponScript>();
                mainHandWeaponDamage = mainHandWeaponScript.GetDamage();
            }
            int glovesDamage = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesDamage = glovesScript.damageBonus;
            }
            return mainHandWeaponDamage + glovesDamage;
        }
    }
    public int offHandDamage
    {
        get
        {
            int offHandWeaponDamage = 0;
            if (offHandWeapon != null)
            {
                WeaponScript offHandWeaponScript = offHandWeapon.GetComponent<WeaponScript>();
                offHandWeaponDamage = offHandWeaponScript.GetDamage();
            }
            int glovesDamage = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesDamage = glovesScript.damageBonus;
            }
            return offHandWeaponDamage + glovesDamage;
        }
    }
    public int spellDamage
    {
        get
        {
            int amuletSpellDamage = 0;
            if (amulet != null)
            {
                AmuletScript amuletScript = amulet.GetComponent<AmuletScript>();
                amuletSpellDamage = amuletScript.spellDamage;
            }
            int glovesDamage = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesDamage = glovesScript.damageBonus;
            }
            return amuletSpellDamage + glovesDamage;
        }
    }
    public int pickupRadius
    {
        get
        {
            int effectiveRadius = enchantmentModifiers.pickupRadius;
            if (pants != null)
            {
                PantsScript pantsScript = pants.GetComponent<PantsScript>();
                effectiveRadius += pantsScript.pickupRadius;
            }
            return effectiveRadius;
        }
    }
    public int aggroRange;
    public Vector3 previousPosition = new Vector3();
    public GameObject[] equippedSkills
    {
        get
        {
            GameObject[] skillArray = new GameObject[8];
            if (mainHandWeapon != null)
            {
                WeaponScript mainHandWeaponScript = mainHandWeapon.GetComponent<WeaponScript>();
                skillArray[0] = mainHandWeaponScript.FirstSkill();
                skillArray[1] = mainHandWeaponScript.SecondSkill();
            }
            if (offHandWeapon != null)
            {
                WeaponScript offHandWeaponScript = offHandWeapon.GetComponent<WeaponScript>();
                skillArray[2] = offHandWeaponScript.ThirdSkill();
            }
            if (utilitySkills.childCount > 0)
            {
                for (int i = 0; i < utilitySkills.childCount; i++)
                {
                    if (i < utilitySkillSlots)
                    {
                        GameObject utilitySkill = utilitySkills.GetChild(i).gameObject;
                        Skill skillScript = utilitySkill.GetComponent<Skill>();
                        int skillIndex = skillScript.skillBarPosition - 1;
                        if (skillArray[skillIndex] != null)
                        {
                            Debug.LogError($"there is already a skill in slot {skillIndex}");
                        }
                        else
                        {
                            skillArray[skillIndex] = utilitySkill;
                        }
                    }
                }
            }
            return skillArray;
        }
    }
    public Dictionary<string, int> cooldownTracker = new Dictionary<string, int>();
    private bool isActive = false;
    public bool IsActive
    {
        get
        {
            return isActive;
        }
        set
        {
            Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
            if (value == true && enemyLookup.ContainsKey(this.transform.position))
            {
                if (!enemiesScript.activeEnemyLookup.ContainsKey(this.transform.position))
                {
                    DisplayAggro();
                    FaceTowards(player.transform.position);
                    enemiesScript.activeEnemyLookup.Add(this.transform.position, this.gameObject);
                }
            }
            isActive = value;
        }
    }
    public float minRange
    {
        get
        {
            List<float> skillRanges = new List<float>();
            for (int i = 0; i < equippedSkills.Length; i++)
            {
                GameObject skill = equippedSkills[i];
                if (skill != null)
                {
                    Skill skillScript = skill.GetComponent<Skill>();
                    float skillRange = skillScript.GetRange();
                    if (skillRange > 0)
                    {
                        float effectiveRange = skillRange + enchantmentModifiers.range;
                        skillRanges.Add(effectiveRange);
                    }
                }
            }
            return skillRanges.Min();
        }
    }
    // effects
    private int _stunDuration = 0;
    public int stunDuration
    {
        get
        {
            return _stunDuration;
        }
        set
        {
            _stunDuration = value;
            DisplayStun();
        }
    }
    public GameObject stunEffect;
    private int _reflectDuration = 0;
    public int reflectDuration
    {
        get
        {
            return _reflectDuration;
        }
        set
        {
            _reflectDuration = value;
            DisplayReflect();
        }
    }
    public GameObject reflectEffect;
    public Transform enchantments;
    private bool isDisplacing = false;
    List<GameObject> activeEnchantments
    {
        get
        {
            List<GameObject> enchantmentList = new List<GameObject>();
            if (enchantments != null && enchantments.childCount > 0)
            {
                for (int i = 0; i < enchantments.childCount; i++)
                {
                    GameObject enchantment = enchantments.GetChild(i).gameObject;
                    enchantmentList.Add(enchantment);
                }
            }
            return enchantmentList;
        }
    }

    public class Modifiers
    {
        public int outgoingDamage;
        public int incomingDamage;
        public int speed;
        public float range;
        public int duration;
        public int outgoingStunDuration;
        public int incomingStunDuration;
        public int pickupRadius;
    }

    public Modifiers enchantmentModifiers
    {
        get
        {
            Modifiers totalModifiers = new Modifiers();
            foreach (GameObject enchantment in activeEnchantments)
            {
                EnchantmentScript enchantmentScript = enchantment.GetComponent<EnchantmentScript>();
                Modifiers modifiers = enchantmentScript.ModifierEffects();
                totalModifiers.outgoingDamage += modifiers.outgoingDamage;
                totalModifiers.incomingDamage += modifiers.incomingDamage;
                totalModifiers.speed += modifiers.speed;
                totalModifiers.range += modifiers.range;
                totalModifiers.duration += modifiers.duration;
                totalModifiers.outgoingStunDuration += modifiers.outgoingStunDuration;
                totalModifiers.incomingStunDuration += modifiers.incomingStunDuration;
                totalModifiers.pickupRadius += modifiers.pickupRadius;
            }
            return totalModifiers;
        }
    }

    public void DisplayDamage(int damage)
    {
        // create black outline/shadow text
        GameObject shadowTextObject = new GameObject("Damage Shadow Text Object");
        shadowTextObject.transform.parent = spriteObject.transform;
        shadowTextObject.transform.localPosition = new Vector3(0.55f, 1.45f, 0);
        TextMeshPro shadowTextMesh = shadowTextObject.AddComponent<TextMeshPro>();
        TMP_FontAsset pixelFont = Resources.Load<TMP_FontAsset>("fs-pixel-sans-unicode-regular");
        if (pixelFont != null)
        {
            shadowTextMesh.font = pixelFont;
        }
        shadowTextMesh.text = damage.ToString();
        shadowTextMesh.fontSize = 8;
        shadowTextMesh.alignment = TextAlignmentOptions.Center;
        shadowTextMesh.color = Color.black;
        shadowTextMesh.GetComponent<MeshRenderer>().sortingLayerName = "Effects";
        shadowTextMesh.GetComponent<MeshRenderer>().sortingOrder = 2;

        // create white text on top
        GameObject damageTextObject = new GameObject("Damage Text Object");
        damageTextObject.transform.parent = spriteObject.transform;
        damageTextObject.transform.localPosition = new Vector3(0.5f, 1.5f, 0);
        TextMeshPro damageTextMesh = damageTextObject.AddComponent<TextMeshPro>();
        if (pixelFont != null)
        {
            damageTextMesh.font = pixelFont;
        }
        damageTextMesh.text = damage.ToString();
        damageTextMesh.fontSize = 8;
        damageTextMesh.alignment = TextAlignmentOptions.Center;
        damageTextMesh.color = Color.white;
        damageTextMesh.GetComponent<MeshRenderer>().sortingLayerName = "Effects";
        damageTextMesh.GetComponent<MeshRenderer>().sortingOrder = 3;

        Destroy(shadowTextObject, 0.5f);
        Destroy(damageTextObject, 0.5f);
    }

    public void DisplayStun()
    {
        if (stunDuration > 0)
        {
            if (stunEffect == null)
            {
                stunEffect = new GameObject("Stun Sprite Object");
                stunEffect.transform.parent = spriteObject.transform;
                stunEffect.transform.localPosition = new Vector3(0, 1f, 0);
                SpriteRenderer stunRenderer = stunEffect.AddComponent<SpriteRenderer>();
                stunRenderer.sortingLayerName = "Effects";
                stunRenderer.sortingOrder = 1;
                stunRenderer.sprite = stunSprite;
            }
        }
        else
        {
            if (stunEffect != null)
            {
                Destroy(stunEffect);
            }
        }
    }

    public void DisplayReflect()
    {
        if (reflectDuration > 0)
        {
            if (reflectEffect == null)
            {
                reflectEffect = new GameObject("Reflect Sprite Object");
                reflectEffect.transform.parent = spriteObject.transform;
                reflectEffect.transform.localPosition = new Vector3(0, 0.5f, 0);
                SpriteRenderer reflectRenderer = reflectEffect.AddComponent<SpriteRenderer>();
                reflectRenderer.sortingLayerName = "Effects";
                reflectRenderer.sortingOrder = 1; // to-do - fix these
                reflectRenderer.sprite = reflectSprite;
            }
        }
        else
        {
            if (reflectEffect != null)
            {
                Destroy(reflectEffect);
            }
        }
    }

    public void DisplayEnchantments()
    {
        int enchantmentCount = activeEnchantments.Count;
        if (enchantmentCount == 0)
        {
            Destroy(displayedEnchantments);
            return;
        }
        if (displayedEnchantments == null)
        {
            displayedEnchantments = new GameObject("Displayed Enchantments Sprite Object");
            displayedEnchantments.transform.parent = spriteObject.transform;
            displayedEnchantments.transform.localPosition = new Vector3(1f, 0.5f, 0);
            enchantmentRenderer = displayedEnchantments.AddComponent<SpriteRenderer>();
        }
        if (displayedEnchantments != null)
        {
            enchantmentRenderer.sortingLayerName = "Effects";
            enchantmentRenderer.sortingOrder = 1;
            if (enchantmentCount > 5)
            {
                enchantmentCount = 5;
            }
            enchantmentRenderer.sprite = enchantmentSprites[enchantmentCount - 1];
        }
    }

    public void DisplayUsedSkill(Sprite skillSprite)
    {
        GameObject usedSkillObject = new GameObject("Used Skill Sprite Object");
        usedSkillObject.transform.parent = spriteObject.transform;
        usedSkillObject.transform.localPosition = new Vector3(0, 1.5f, 0);
        SpriteRenderer usedSkillRenderer = usedSkillObject.AddComponent<SpriteRenderer>();
        usedSkillRenderer.sortingOrder = 3;
        usedSkillRenderer.sprite = skillSprite;
        Destroy(usedSkillObject, 0.5f);
    }

    public void DisplayAggro()
    {
        GameObject aggroObject = new GameObject("Aggro Sprite Object");
        aggroObject.transform.parent = spriteObject.transform;
        aggroObject.transform.localPosition = new Vector3(0, 1.125f, 0);
        SpriteRenderer aggroRenderer = aggroObject.AddComponent<SpriteRenderer>();
        aggroRenderer.sortingLayerName = "Effects";
        aggroRenderer.sortingOrder = 2;
        aggroRenderer.sprite = aggroSprite;
        Destroy(aggroObject, 0.5f);
    }

    public void DisplayHit()
    {
        GameObject hitObject = new GameObject("Hit Sprite Object");
        hitObject.transform.parent = spriteObject.transform;
        hitObject.transform.localPosition = new Vector3(0, 0.375f, 0);
        SpriteRenderer hitRenderer = hitObject.AddComponent<SpriteRenderer>();
        hitRenderer.sortingLayerName = "Effects";
        hitRenderer.sortingOrder = 2;
        hitRenderer.sprite = hitSprite;
        Destroy(hitObject, 0.125f);
    }

    public void FaceTowards(Vector3 targetPosition)
    {
        float xDif = targetPosition.x - this.transform.position.x;
        if (xDif < 0)
        {
            spriteRenderer.sprite = SpriteSheet[1];
        }
        else if (xDif > 0)
        {
            spriteRenderer.sprite = SpriteSheet[0];
        }
    }

    public void DisplayHealth()
    {   if (!levelBuilderLoaded)
        {
            return;
        }
        if (healthBar == null)
        {
            healthBar = new GameObject("Entity Health Bar");
            healthBar.transform.parent = spriteObject.transform;
            healthBar.transform.localPosition = new Vector3(0, 1.5f, 0);
            healthBarRenderer = healthBar.AddComponent<SpriteRenderer>();
            healthBarRenderer.sortingLayerName = "Effects";
            healthBarRenderer.sortingOrder = 2;
        }
        Sprite healthBarSprite = null;
        float healthPercentage = (float)currentHealth / (float)maxHealth;
        switch (healthPercentage)
        {
            case < 0.125f:
                healthBarSprite = healthBarStates[0];
                break;
            case >= 0.125f and < 0.250f:
                healthBarSprite = healthBarStates[1];
                break;
            case >= 0.250f and < 0.375f:
                healthBarSprite = healthBarStates[2];
                break;
            case >= 0.375f and < 0.500f:
                healthBarSprite = healthBarStates[3];
                break;
            case >= 0.500f and < 0.625f:
                healthBarSprite = healthBarStates[4];
                break;
            case >= 0.625f and < 0.750f:
                healthBarSprite = healthBarStates[5];
                break;
            case >= 0.750f and < 0.875f:
                healthBarSprite = healthBarStates[6];
                break;
            case >= 0.875f and < 1:
                healthBarSprite = healthBarStates[7];
                break;
            case >= 1:
                healthBarSprite = healthBarStates[8];
                break;
        }
        if (healthBarSprite != null)
        {
            healthBarRenderer.sprite = healthBarSprite;
        }
    }

    public void MoveTo(Vector3 targetPosition)
    {
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        GameObject targetTile = tileLookup[targetPosition];
        TileScript targetTileScript = targetTile.GetComponent<TileScript>();
        // flip sprite if moving left, unflip if moving right
        Vector3 currentPosition = this.transform.position;
        FaceTowards(targetPosition);
        GameObject currentTile = tileLookup[currentPosition];
        TileScript currentTileScript = currentTile.GetComponent<TileScript>();
        targetTileScript.isOccupied = true;
        currentTileScript.isOccupied = false;
        previousPosition = currentPosition;
        // update enemy lookups
        if (enemiesScript.enemyLookup.ContainsKey(currentPosition) && enemiesScript.enemyLookup[currentPosition] == this.gameObject)
        {
            enemiesScript.EnemyMoved(currentPosition, targetPosition);
        }
        this.transform.position = targetPosition;
        // pick up ground items
        List<Vector3> pickupDeltas = new List<Vector3>();
        for (float i = -pickupRadius; i <= pickupRadius; i++)
        {
            for (float j = -pickupRadius; j <= pickupRadius; j++)
            {
                Vector3 delta = new Vector3(i, j, 0);
                pickupDeltas.Add(delta);
            }
        }
        foreach (Vector3 delta in pickupDeltas)
        {
            Vector3 pickupPosition = this.transform.position + delta;
            if (dropsScript.groundItemsLookup.ContainsKey(pickupPosition))
            {
                GameObject groundItems = dropsScript.groundItemsLookup[pickupPosition];
                while (groundItems.transform.childCount > 0 && inventory.childCount <= inventorySize)
                {
                    Transform item = groundItems.transform.GetChild(0);
                    ItemScript itemScript = item.GetComponent<ItemScript>();
                    // cache the inventory array once to avoid repeated getter calls
                    GameObject[] currentInventory = inventoryItems;
                    // find first empty inventory slot
                    bool foundSlot = false;
                    for (int i = 0; i < inventorySize; i++)
                    {
                        if (currentInventory[i] == null)
                        {
                            itemScript.inventoryPosition = i + 1;
                            item.parent = inventory;
                            MissionLogicScript.Instance.totalSalvage += itemScript.SalvageValue();
                            foundSlot = true;
                            break;
                        }
                    }
                    // if no empty slot found, inventory is full
                    if (!foundSlot)
                    {
                        break;
                    }
                    // refresh open inventory menu
                    Transform characterUI = GameObject.Find("Character UI").transform;
                    Transform inventoryMenu = characterUI.Find("Inventory Menu(Clone)");
                    if (inventoryMenu != null)
                    {
                        InventoryMenuScript inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
                        inventoryMenuScript.RefreshUI();
                    }
                }
                if (groundItems.transform.childCount == 0)
                {
                    dropsScript.groundItemsLookup.Remove(pickupPosition);
                    Destroy(groundItems);
                }
                else
                {
                    Debug.Log("inventory full");
                }
            }
        }
        // update aggro and finish level if player is on level end
        if (targetPosition == player.transform.position)
        {
            enemiesScript.UpdateAggro();
            if (enemiesScript.activeEnemyLookup.Count == 0 && targetTileScript.IsEnd)
            {
                MissionLogicScript.Instance.currentLevel += 1;
                MissionLogicScript.Instance.NextLevel();
            }
        }
    }

    public int Attack(int damage, GameObject defender)
    {
        OnAttackEnchantmentEffects(defender);
        FaceTowards(defender.transform.position);
        if (!isDisplacing)
        {
            StartCoroutine(AttackDisplacement(defender));
        }
        return OutgoingDamage(damage, defender);
    }

    IEnumerator AttackDisplacement(GameObject defender)
    {
        isDisplacing = true;
        Vector3 difference = defender.transform.position - this.transform.position;
        Vector3 offset = difference / 16f;
        spriteObject.transform.localPosition = offset;
        yield return new WaitForSeconds(0.25f);
        spriteObject.transform.localPosition = Vector3.zero;
        isDisplacing = false;
    }

    public int OutgoingDamage(int damage, GameObject defender)
    {
        EntityScript defenderScript = defender.GetComponent<EntityScript>();
        int effectiveDamage = damage + enchantmentModifiers.outgoingDamage;
        return defenderScript.IncomingDamage(effectiveDamage, this.gameObject);
    }

    public int IncomingDamage(int damage, GameObject attacker, bool isReflected = false)
    {
        DisplayHit();
        if (!IsActive)
        {
            IsActive = true;
        }
        if (reflectDuration > 0 && !isReflected)
        {
            EntityScript attackerScript = attacker.GetComponent<EntityScript>();
            attackerScript.IncomingDamage(damage, this.gameObject, true);
            return 0;
        }
        int effectiveDamage = damage + enchantmentModifiers.incomingDamage;
        // half of incoming damage is reduced by armor
        int halfDamage = effectiveDamage / 2;
        int armorDamage = (effectiveDamage - halfDamage - Armor);
        if (armorDamage < 0)
        {
            armorDamage = 0;
        }
        int actualDamage = halfDamage + armorDamage;
        if (actualDamage <= 0)
        {
            return 0;
        }
        else
        {
            DisplayDamage(actualDamage);
            CurrentHealth -= actualDamage;
            Debug.Log(this.gameObject.name + " took " + actualDamage.ToString() + " damage from " + attacker.name);
            if (this.gameObject == player)
            {
                MissionLogicScript.Instance.totalIncomingDamage += actualDamage;
            }
            else
            {
                MissionLogicScript.Instance.totalOutgoingDamage += actualDamage;
            }
            return actualDamage;
        }
    }

    public void Knockback(Vector3 fromPosition, GameObject attacker, int collisionDamage)
    {
        EntityScript attackerScript = attacker.GetComponent<EntityScript>();
        Vector3 difference = this.transform.position - fromPosition;
        Vector3 targetPosition = this.transform.position + difference;
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        if (tileLookup.ContainsKey(targetPosition))
        {
            GameObject tile = tileLookup[targetPosition];
            TileScript tileScript = tile.GetComponent<TileScript>();
            if (tileScript.isOccupied)
            {
                attackerScript.Attack(collisionDamage, this.gameObject);
            }
            else
            {
                MoveTo(targetPosition);
            }
        }
        else
        {
            attackerScript.Attack(collisionDamage, this.gameObject);
        }
    }

    public int GetSkillCooldown(string skillName)
    {
        if (cooldownTracker.ContainsKey(skillName))
        {
            return cooldownTracker[skillName];
        }
        else
        {
            return 0;
        }
    }

    public void SetSkillCooldown(string skillName, int number)
    {
        if (cooldownTracker.ContainsKey(skillName))
        {
            cooldownTracker[skillName] = number;
        }
        else
        {
            cooldownTracker.Add(skillName, number);
        }
        SkillBarScript.Instance.DisplayCooldowns();
    }

    public void ReduceSkillCooldown(string skillName, int number)
    {
        if (!cooldownTracker.ContainsKey(skillName))
        {
            Debug.LogError("trying to reduce cooldown of skill {skillName} which isn't in the tracker");
            return;
        }
        cooldownTracker[skillName] -= number;
        if (cooldownTracker[skillName] < 0)
        {
            cooldownTracker[skillName] = 0;
        }
    }

    public void ReduceCooldowns(int number)
    {
        List<string> trackedCooldowns = cooldownTracker.Keys.ToList();
        foreach (string skillName in trackedCooldowns)
        {
            ReduceSkillCooldown(skillName, number);
        }
        SkillBarScript.Instance.DisplayCooldowns();
    }

    public void ReduceStunDuration(int number)
    {
        stunDuration -= number;
        if (stunDuration < 0)
        {
            stunDuration = 0;
        }
    }

    public void ReduceEffectDurations(int number)
    {
        reflectDuration -= number;
        if (reflectDuration < 0)
        {
            reflectDuration = 0;
        }
    }

    public void ReduceEnchantmentDurations(int number)
    {
        foreach (GameObject enchantment in activeEnchantments)
        {
            EnchantmentScript enchantmentScript = enchantment.GetComponent<EnchantmentScript>();
            enchantmentScript.currentDuration -= 1;
            if (enchantmentScript.currentDuration <= 0)
            {
                enchantmentScript.EndEffect(this.gameObject);
                DestroyImmediate(enchantment);
            }
        }
    }

    public void OnAttackEnchantmentEffects(GameObject target)
    {
        foreach (GameObject enchantment in activeEnchantments)
        {
            EnchantmentScript enchantmentScript = enchantment.GetComponent<EnchantmentScript>();
            enchantmentScript.OnAttackEffect(target, this.gameObject);
        }
    }

    public void EndOfTurnEnchantmentEffects()
    {
        foreach (GameObject enchantment in activeEnchantments)
        {
            EnchantmentScript enchantmentScript = enchantment.GetComponent<EnchantmentScript>();
            enchantmentScript.EndOfTurnEffect(this.gameObject);
        }
    }

    public void DropItems()
    {
        // only drop items if this is an enemy
        if (!enemiesScript.enemyLookup.ContainsKey(this.transform.position))
        {
            return;
        }
        // check if there are ground items already
        GameObject groundItems;
        if (dropsScript.groundItemsLookup.ContainsKey(this.transform.position))
        {
            groundItems = dropsScript.groundItemsLookup[this.transform.position];
        }
        else
        {
            GameObject groundItemsPrefab = Resources.Load<GameObject>("Prefabs/Ground Items");
            groundItems = Instantiate(groundItemsPrefab, drops.transform);
            groundItems.transform.position = this.transform.position;
            dropsScript.groundItemsLookup.Add(this.transform.position, groundItems);
        }
        // drop inventory
        List<Transform> inventoryList = new List<Transform>();
        for (int i = 0; i < inventory.childCount; i++)
        {
            inventoryList.Add(inventory.GetChild(i));
        }
        foreach (Transform inventoryItem in inventoryList)
        {
            inventoryItem.parent = groundItems.transform;
        }
        // prepare to drop random item
        List<GameObject> equippedGear = new List<GameObject>();
        if (mainHandWeapon != null)
        {
            equippedGear.Add(mainHandWeapon);
        }
        if (offHandWeapon != null)
        {
            equippedGear.Add(offHandWeapon);
        }
        if (amulet != null)
        {
            equippedGear.Add(amulet);
        }
        if (coat != null)
        {
            equippedGear.Add(coat);
        }
        if (pants != null)
        {
            equippedGear.Add(pants);
        }
        if (gloves != null)
        {
            equippedGear.Add(gloves);
        }
        if (boots != null)
        {
            equippedGear.Add(boots);
        }
        List<GameObject> equippedUtilitySkills = new List<GameObject>();
        for (int i = 0; i < utilitySkills.childCount; i++)
        {
            equippedUtilitySkills.Add(utilitySkills.GetChild(i).gameObject);
        }
        // pick 1 random gear piece or utility skill to drop
        if (equippedGear.Count > 0 || equippedUtilitySkills.Count > 0)
        {
            int totalCount = equippedGear.Count + equippedUtilitySkills.Count;
            int randomIndex = Random.Range(0, totalCount);
            if (randomIndex < equippedGear.Count)
            {
                GameObject gearDrop = equippedGear[randomIndex];
                gearDrop.transform.parent = groundItems.transform;
            }
            else
            {
                int skillIndex = randomIndex - equippedGear.Count;
                GameObject skillDrop = equippedUtilitySkills[skillIndex];
                Skill skillScript = skillDrop.GetComponent<Skill>();
                GameObject skillTomePrefab = Resources.Load<GameObject>("Prefabs/Skill Tome");
                GameObject tomeDrop = Instantiate(skillTomePrefab, groundItems.transform);
                SkillTomeScript tomeScript = tomeDrop.GetComponent<SkillTomeScript>();
                tomeScript.skillName = skillScript.GetSkillName();
            }
        }
    }

    IEnumerator WaitForGearBeforePopulating()
    {
        while (!gearScript.finishedBuilding)
        {
            yield return null;
        }
        while (!levelBuilderScript.finishedBuilding)
        {
            yield return null;
        }
        finishedBuilding = true;
    }

    void Awake()
    {
        // create sprite object child and move renderer to it
        spriteObject = new GameObject("Sprite Object");
        spriteObject.transform.parent = this.transform;
        spriteObject.transform.localPosition = Vector3.zero;
        SpriteRenderer oldRenderer = this.gameObject.GetComponent<SpriteRenderer>();
        spriteRenderer = spriteObject.AddComponent<SpriteRenderer>();
        if (oldRenderer != null)
        {
            spriteRenderer.sortingLayerName = oldRenderer.sortingLayerName;
            spriteRenderer.sortingOrder = oldRenderer.sortingOrder;
            Destroy(oldRenderer);
        }
    }

    void Start()
    {
        Debug.Log("Hello World - I'm " + this.name);
        if (this.gameObject.name == "Player")
        {
            SpriteSheet = Resources.LoadAll<Sprite>("Player");
            maxHealth = 10;
        }
        levelBuilder = GameObject.Find("Level Builder");
        levelBuilderScript = levelBuilder.GetComponent<LevelBuilderScript>();
        levelBuilderLoaded = true;
        traversableTiles = GameObject.Find("Traversable Tiles");
        traversableTilesScript = traversableTiles.GetComponent<TraversableTilesScript>();
        player = GameObject.Find("Player");
        enemies = GameObject.Find("Enemies");
        enemiesScript = enemies.GetComponent<EnemiesScript>();
        drops = GameObject.Find("Drops");
        dropsScript = drops.GetComponent<DropsScript>();
        gear = this.transform.Find("Gear").gameObject;
        gearScript = gear.GetComponent<GearScript>();
        hitSprite = Resources.Load<Sprite>("Hit");
        aggroSprite = Resources.Load<Sprite>("EnemyAggro");
        stunSprite = Resources.Load<Sprite>("StunEffect");
        reflectSprite = Resources.Load<Sprite>("ReflectEffect");
        healthBarStates = Resources.LoadAll<Sprite>("EntityHealthBars");
        enchantmentSprites = Resources.LoadAll<Sprite>("EntityEnchantments");
        _mainHand = gear.transform.Find("Main Hand");
        _offHand = gear.transform.Find("Off Hand");
        _neck = gear.transform.Find("Neck");
        _body = gear.transform.Find("Body");
        _hands = gear.transform.Find("Hands");
        _legs = gear.transform.Find("Legs");
        _feet = gear.transform.Find("Feet");
        _inventory = this.transform.Find("Inventory");
        _inventorySize = 24;
        _utilitySkills = this.transform.Find("Utility Skills");
        enchantments = this.transform.Find("Enchantments");
        StartCoroutine(WaitForGearBeforePopulating());
    }

    void OnDestroy()
    {
    }
}
