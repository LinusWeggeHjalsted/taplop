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
    public GameObject mainHandWeaponSprite;
    public SpriteRenderer mainHandWeaponSpriteRenderer;
    public GameObject offHandWeaponSprite;
    public SpriteRenderer offHandWeaponSpriteRenderer;
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

    private int momentum;
    public int Momentum
    {
        get
        {
            return momentum;
        }
        set
        {
            momentum = value;
            if (momentum < 0)
            {
                momentum = 0;
            }
            if (this.gameObject == player)
            {
                GameObject momentumUI = LevelScript.Instance.momentumUI;
                MomentumUIScript momentumScript = momentumUI.GetComponent<MomentumUIScript>();
                momentumScript.UpdateMomentum();
            }
        }
    }
    public int convertedMomentum
    {
        get
        {
            if (Momentum <= 1)
            {
                return 0;
            }
            else
            {
                return (int)Mathf.Log(Momentum, 2);
            }
        }
    }
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
            int glovesHealth = 0;
            if (gloves != null)
            {
                GlovesScript glovesScript = gloves.GetComponent<GlovesScript>();
                glovesHealth = glovesScript.healthBonus;
            }
            int pantsHealth = 0;
            if (pants != null)
            {
                PantsScript pantsScript = pants.GetComponent<PantsScript>();
                pantsHealth = pantsScript.healthBonus;
            }
            int bootsHealth = 0;
            if (boots != null)
            {
                BootsScript bootsScript = boots.GetComponent<BootsScript>();
                bootsHealth = bootsScript.healthBonus;
            }
            return maxHealth + coatHealth + glovesHealth + pantsHealth + bootsHealth;
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
            if (this.gameObject == player && LevelScript.Instance != null)
            {
                GameObject playerHealthBar = LevelScript.Instance.playerHealthBar;
                if (playerHealthBar != null)
                {
                    PlayerHealthBarScript playerHealthBarScript = playerHealthBar.GetComponent<PlayerHealthBarScript>();
                    playerHealthBarScript.UpdateHealthBar();
                }
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
            return armor + coatArmor;
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
    private GameObject[] _equippedSkillsCache = null;
    public GameObject[] equippedSkills
    {
        get
        {
            if (_equippedSkillsCache == null)
            {
                UpdateEquippedSkills();
            }
            return _equippedSkillsCache;
        }
    }

    public void UpdateEquippedSkills()
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
                    SkillScript skillScript = utilitySkill.GetComponent<SkillScript>();
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
        _equippedSkillsCache = skillArray;
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
                    if (enemiesScript.activeEnemyLookup.Count == 1 && LevelScript.Instance != null)
                    {
                        GameObject attackStepButton = LevelScript.Instance.attackStepButton;
                        if (attackStepButton != null)
                        {
                            AttackStepButtonScript attackStepButtonScript = attackStepButton.GetComponent<AttackStepButtonScript>();
                            attackStepButtonScript.ForceEnabledInCombat();
                        }
                        // until all active enemies are dead
                    }
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
            GameObject[] skills = equippedSkills;
            for (int i = 0; i < skills.Length; i++)
            {
                GameObject skill = skills[i];
                if (skill != null)
                {
                    SkillScript skillScript = skill.GetComponent<SkillScript>();
                    float skillRange = skillScript.GetRange();
                    float skillRadius = skillScript.GetRadius();
                    if (skillRange > 0)
                    {
                        float effectiveRange = skillRange + enchantmentModifiers.range;
                        skillRanges.Add(effectiveRange);
                    }
                    else if (skillRadius > 0)
                    {
                        float effectiveRadius = skillRadius + enchantmentModifiers.radius;
                        skillRanges.Add(effectiveRadius);
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
    public List<GameObject> activeEnchantments
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
        public float radius;
        public float distance;
        public int skillDuration;
        public int stunDuration;
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
                totalModifiers.radius += modifiers.radius;
                totalModifiers.distance += modifiers.distance;
                totalModifiers.skillDuration += modifiers.skillDuration;
                totalModifiers.stunDuration += modifiers.stunDuration;
                totalModifiers.outgoingStunDuration += modifiers.outgoingStunDuration;
                totalModifiers.incomingStunDuration += modifiers.incomingStunDuration;
                totalModifiers.pickupRadius += modifiers.pickupRadius;
            }
            return totalModifiers;
        }
    }

    public void DisplayWeapons()
    {
        string mainHandType = "none";
        string offHandType = "none";
        if (mainHandWeapon != null)
        {
            WeaponScript mainHandScript = mainHandWeapon.GetComponent<WeaponScript>();
            mainHandType = mainHandScript.ItemSubType();
        }
        if (offHandWeapon != null)
        {
            WeaponScript offHandScript = offHandWeapon.GetComponent<WeaponScript>();
            offHandType = offHandScript.ItemSubType();
        }
        if (mainHandType != "none")
        {
            if (this.gameObject != player)
            {
                mainHandType = "Enemy" + mainHandType;
            }
            Sprite[] mainHandSprites = Resources.LoadAll<Sprite>($"Weapons/{mainHandType}");
            mainHandWeaponSpriteRenderer.sprite = mainHandSprites[0];
        }
        if (offHandType != "none")
        {
            if (this.gameObject != player)
            {
                offHandType = "Enemy" + offHandType;
            }
            Sprite[] offHandSprites = Resources.LoadAll<Sprite>($"Weapons/{offHandType}");
            offHandWeaponSpriteRenderer.sprite = offHandSprites[0];
        }
    }

    public void DisplayDamage(int damage)
    {
        float spriteTopLocal = spriteRenderer.bounds.max.y - spriteObject.transform.position.y;
        // create black outline/shadow text
        GameObject shadowTextObject = new GameObject("Damage Shadow Text Object");
        shadowTextObject.transform.parent = spriteObject.transform;
        shadowTextObject.transform.localPosition = new Vector3(0.55f, spriteTopLocal + 0.45f, 0);
        TextMeshPro shadowTextMesh = shadowTextObject.AddComponent<TextMeshPro>();
        TMP_FontAsset pixelFont = Resources.Load<TMP_FontAsset>("FreeZilla-Regular SDF");
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
        damageTextObject.transform.localPosition = new Vector3(0.5f, spriteTopLocal + 0.5f, 0);
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
                float spriteTopLocal = spriteRenderer.bounds.max.y - spriteObject.transform.position.y;
                stunEffect = new GameObject("Stun Sprite Object");
                stunEffect.transform.parent = spriteObject.transform;
                stunEffect.transform.localPosition = new Vector3(0, spriteTopLocal, 0);
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
        if (this.gameObject == player)
        {
            PlayerEnchantmentsScript.Instance.UpdateEnchantments();
        }
        int enchantmentCount = activeEnchantments.Count;
        if (enchantmentCount == 0)
        {
            Destroy(displayedEnchantments);
            return;
        }
        float spriteTopLocal = spriteRenderer.bounds.max.y - spriteObject.transform.position.y;
        if (displayedEnchantments == null)
        {
            displayedEnchantments = new GameObject("Displayed Enchantments Sprite Object");
            displayedEnchantments.transform.parent = spriteObject.transform;
            enchantmentRenderer = displayedEnchantments.AddComponent<SpriteRenderer>();
        }
        displayedEnchantments.transform.localPosition = new Vector3(1f, spriteTopLocal - 0.5f, 0);
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
        if (spriteObject == null)
        {
            return;
        }
        float spriteTopLocal = spriteRenderer.bounds.max.y - spriteObject.transform.position.y;
        GameObject usedSkillObject = new GameObject("Used Skill Sprite Object");
        usedSkillObject.transform.parent = spriteObject.transform;
        usedSkillObject.transform.localPosition = new Vector3(0, spriteTopLocal + 0.5f, 0);
        SpriteRenderer usedSkillRenderer = usedSkillObject.AddComponent<SpriteRenderer>();
        usedSkillRenderer.sortingLayerName = "Effects";
        usedSkillRenderer.sortingOrder = 1;
        usedSkillRenderer.sprite = skillSprite;
        usedSkillRenderer.color = MissionLogicScript.Instance.interfaceColors[1];
        Destroy(usedSkillObject, 0.5f);
    }

    public void DisplayAggro()
    {
        float spriteTopLocal = spriteRenderer.bounds.max.y - spriteObject.transform.position.y;
        GameObject aggroObject = new GameObject("Aggro Sprite Object");
        aggroObject.transform.parent = spriteObject.transform;
        aggroObject.transform.localPosition = new Vector3(0, spriteTopLocal + 0.125f, 0);
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
        hitObject.transform.localPosition = new Vector3(0, 0.625f, 0);
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
            spriteRenderer.sprite = SpriteSheet[0];
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
            healthBarRenderer = healthBar.AddComponent<SpriteRenderer>();
            healthBarRenderer.sortingLayerName = "Effects";
            healthBarRenderer.sortingOrder = 2;
        }
        float spriteTopLocal = spriteRenderer.bounds.max.y - spriteObject.transform.position.y;
        healthBar.transform.localPosition = new Vector3(0, spriteTopLocal, 0);
        Sprite healthBarSprite = null;
        float healthPercentage = (float)CurrentHealth / (float)MaxHealth;
        switch (healthPercentage)
        {
            case 0.0f:
                healthBarSprite = healthBarStates[0];
                break;
            case < 0.125f:
                // always leave a pixel of health if nonzero
                healthBarSprite = healthBarStates[1];
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

    public void MoveTo(Vector3 targetPosition, bool isTeleport = false)
    {
        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        GameObject targetTile = tileLookup[targetPosition];
        TileScript targetTileScript = targetTile.GetComponent<TileScript>();
        Vector3 currentPosition = this.transform.position;
        FaceTowards(targetPosition);
        GameObject currentTile = tileLookup[currentPosition];
        TileScript currentTileScript = currentTile.GetComponent<TileScript>();
        targetTileScript.isOccupied = true;
        currentTileScript.isOccupied = false;
        previousPosition = currentPosition;
        this.transform.position = targetPosition; // to-do - should this happen earlier
        spriteRenderer.sortingOrder = 10 * (int)-targetPosition.y;
        mainHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-targetPosition.y + 1;
        offHandWeaponSpriteRenderer.sortingOrder = 10 * (int)-targetPosition.y + 1;
        SoundControllerScript.Instance.PlayMoveSound(targetPosition);
        if (!isTeleport)
        {
            GameObject afterimagePrefab = Resources.Load<GameObject>("Prefabs/Afterimage");
            List<Vector3> shortestPath = traversableTilesScript.ShortestPath(currentPosition, targetPosition);
            shortestPath.Add(currentPosition);
            shortestPath.Reverse();
            GameObject afterimages = GameReferences.GetAfterimages();
            for (int i = 0; i < shortestPath.Count - 1; i++)
            {
                GameObject afterimage = Instantiate(afterimagePrefab, afterimages.transform);
                SpriteRenderer afterimageRenderer = afterimage.GetComponent<SpriteRenderer>();
                afterimage.transform.position = shortestPath[i];
                afterimageRenderer.sortingOrder = 10 * (int)-shortestPath[i].y;
                float xDif = (shortestPath[i + 1] - shortestPath[i]).x;
                if (xDif < 0)
                {
                    afterimageRenderer.sprite = SpriteSheet[1];
                }
                else if (xDif > 0)
                {
                    afterimageRenderer.sprite = SpriteSheet[0];
                }
                else
                {
                    afterimageRenderer.sprite = spriteRenderer.sprite;
                }
                float alpha = (float)(i + 1) / (float)(shortestPath.Count);
                Color afterimageColor = afterimageRenderer.color;
                afterimageColor.a = alpha;
                afterimageRenderer.color = afterimageColor;
                Destroy(afterimage, 0.5f);
            }
        }
        // update enemy lookups
        if (enemiesScript.enemyLookup.ContainsKey(currentPosition) && enemiesScript.enemyLookup[currentPosition] == this.gameObject)
        {
            enemiesScript.EnemyMoved(currentPosition, targetPosition);
        }
        if (this.gameObject == player)
        {
            CameraControllerScript.Instance.MoveToPlayer();
        }
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
                SoundControllerScript.Instance.PlayPickupSound(); // to-do - only play once
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
                    // show pickup notification for player
                    if (this.gameObject == player && LevelScript.Instance != null)
                    {
                        GameObject inventoryButton = LevelScript.Instance.inventoryButton;
                        if (inventoryButton != null)
                        {
                            InventoryButtonScript inventoryButtonScript = inventoryButton.GetComponent<InventoryButtonScript>();
                            Sprite itemSprite = itemScript.GetSprite();
                            inventoryButtonScript.QueuePickupNotification(itemSprite);
                        }
                    }
                }
                if (groundItems.transform.childCount == 0)
                {
                    dropsScript.groundItemsLookup.Remove(pickupPosition);
                    Destroy(groundItems);
                }
                if (this.gameObject == player && LevelScript.Instance != null)
                {
                    // refresh open inventory menu
                    GameObject characterUI = LevelScript.Instance.characterUI;
                    if (characterUI != null)
                    {
                        Transform inventoryMenu = characterUI.transform.Find("Inventory Menu(Clone)");
                        if (inventoryMenu != null)
                        {
                            InventoryMenuScript inventoryMenuScript = inventoryMenu.GetComponent<InventoryMenuScript>();
                            inventoryMenuScript.RefreshUI();
                        }
                    }
                }
            }
        }
        Momentum += 1;
        // update aggro and finish level if player is on level end
        if (this.gameObject == player)
        {
            enemiesScript.UpdateAggro();
            if (enemiesScript.activeEnemyLookup.Count == 0 && targetTileScript.IsEnd)
            {
                MissionLogicScript.Instance.currentLevel += 1;
                MissionLogicScript.Instance.NextLevel();
            }
        }
    }

    public void UsedSkill(SkillScript skillScript, Vector3? targetPosition)
    {
        Sprite skillSprite = skillScript.GetSprite();
        DisplayUsedSkill(skillSprite);
        // to-do - OnSkillUsedEnchantmentEffects();
        Momentum += 1;
        // to-do - save information to combat log
    }

    public int Attack(int damage, GameObject defender)
    {
        OnAttackEnchantmentEffects(defender);
        FaceTowards(defender.transform.position);
        if (!isDisplacing)
        {
            StartCoroutine(AttackDisplacement(defender));
        }
        return OutgoingDamage(damage + convertedMomentum, defender);
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
            SoundControllerScript.Instance.PlayReflectSound(this.transform.position);
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

    public void Knockback(Vector3 fromPosition, GameObject attacker, int collisionDamage, float distance)
    {
        EntityScript attackerScript = attacker.GetComponent<EntityScript>();
        Vector3 entityPosition = this.transform.position;
        Vector3 positionDelta = entityPosition - fromPosition;
        // Normalize to single tile direction
        if (positionDelta.x != 0)
        {
            positionDelta.x = positionDelta.x / Mathf.Abs(positionDelta.x);
        }
        if (positionDelta.y != 0)
        {
            positionDelta.y = positionDelta.y / Mathf.Abs(positionDelta.y);
        }

        Dictionary<Vector3, GameObject> tileLookup = traversableTilesScript.tileLookup;
        Vector3 knockbackDestination = entityPosition;
        bool hitObstacle = false;

        // Check each position from nearest to farthest
        for (int i = 1; i <= distance; i++)
        {
            Vector3 checkPosition = entityPosition + i * positionDelta;
            if (tileLookup.ContainsKey(checkPosition))
            {
                GameObject tile = tileLookup[checkPosition];
                TileScript tileScript = tile.GetComponent<TileScript>();
                bool isOccupied = tileScript.isOccupied;
                // Also check if an enemy is at this position
                if (enemiesScript != null)
                {
                    Dictionary<Vector3, GameObject> enemyLookup = enemiesScript.enemyLookup;
                    if (enemyLookup.ContainsKey(checkPosition))
                    {
                        isOccupied = true;
                    }
                }
                if (!isOccupied)
                {
                    knockbackDestination = checkPosition;
                }
                else
                {
                    hitObstacle = true;
                    break;
                }
            }
            else
            {
                // Hit edge of map
                hitObstacle = true;
                break;
            }
        }

        if (hitObstacle)
        {
            attackerScript.Attack(collisionDamage, this.gameObject);
        }
        if (knockbackDestination != entityPosition)
        {
            MoveTo(knockbackDestination);
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
            SpriteRenderer groundItemsRenderer = groundItems.GetComponent<SpriteRenderer>();
            groundItemsRenderer.sortingOrder = 10 * (int)-groundItems.transform.position.y;
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
        // find equipped gear
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
        // drop all equipped gear
        foreach (GameObject gearDrop in equippedGear)
        {
            gearDrop.transform.parent = groundItems.transform;
        }
        // drop tome for each equipped utility skill
        foreach (GameObject skillDrop in equippedUtilitySkills)
        {
            SkillScript skillScript = skillDrop.GetComponent<SkillScript>();
            GameObject skillTomePrefab = Resources.Load<GameObject>("Prefabs/Items/Skill Tome");
            GameObject tomeDrop = Instantiate(skillTomePrefab, groundItems.transform);
            SkillTomeScript tomeScript = tomeDrop.GetComponent<SkillTomeScript>();
            tomeScript.skillName = skillScript.GetSkillName();
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
        DisplayWeapons();
        finishedBuilding = true;
    }

    void Awake()
    {
        spriteObject = this.transform.Find("Sprite Object").gameObject;
        spriteRenderer = spriteObject.GetComponent<SpriteRenderer>();
        mainHandWeaponSprite = spriteObject.transform.Find("Main Hand Weapon Sprite").gameObject;
        mainHandWeaponSpriteRenderer = mainHandWeaponSprite.GetComponent<SpriteRenderer>();
        offHandWeaponSprite = spriteObject.transform.Find("Off Hand Weapon Sprite").gameObject;
        offHandWeaponSpriteRenderer = offHandWeaponSprite.GetComponent<SpriteRenderer>();
        if (this.gameObject.name == "Player")
        {
            SpriteSheet = Resources.LoadAll<Sprite>("Player");
            maxHealth = 20;
        }
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
        _inventorySize = 24 * 4;
        _utilitySkills = this.transform.Find("Utility Skills");
        enchantments = this.transform.Find("Enchantments");
        levelBuilderLoaded = true;
    }

    void Start()
    {
        if (LevelScript.Instance != null)
        {
            levelBuilder = LevelScript.Instance.levelBuilder;
            levelBuilderScript = LevelScript.Instance.levelBuilderScript;
            traversableTiles = LevelScript.Instance.traversableTiles;
            traversableTilesScript = LevelScript.Instance.traversableTilesScript;
            player = LevelScript.Instance.player;
            enemies = LevelScript.Instance.enemies;
            enemiesScript = LevelScript.Instance.enemiesScript;
            drops = LevelScript.Instance.drops;
            dropsScript = LevelScript.Instance.dropsScript;
        }
        StartCoroutine(WaitForGearBeforePopulating());
    }
}
